"""Reads settings from demo.config.env (repo root) - the Python twin of scripts/lib/cfg.ps1.

Lookup order: environment variable RTI_<KEY>, then demo.config.env, then the default.
A value that is empty or still a placeholder such as <your-subscription-id> counts as missing.
The file path can be overridden with the environment variable RTI_CONFIG.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

_LINE = re.compile(r"^\s*([A-Za-z0-9_]+)\s*=(.*)$")


def _missing(value: str | None) -> bool:
    return value is None or not value.strip() or bool(re.fullmatch(r"<.*>", value.strip()))


def _config_path() -> Path:
    override = os.environ.get("RTI_CONFIG")
    if override and override.strip():
        return Path(override)
    return Path(__file__).resolve().parents[2] / "demo.config.env"


def get(key: str, default: str = "", required: bool = False) -> str:
    value: str | None = os.environ.get(f"RTI_{key}")
    if _missing(value):
        value = None
        path = _config_path()
        if path.is_file():
            for raw in path.read_text(encoding="utf-8-sig").splitlines():
                if raw.lstrip().startswith("#"):
                    continue
                match = _LINE.match(raw)
                if not match or match.group(1) != key:
                    continue
                candidate = match.group(2).strip()
                if len(candidate) >= 2 and candidate[0] == candidate[-1] and candidate[0] in "\"'":
                    candidate = candidate[1:-1]
                if not _missing(candidate):
                    value = candidate
        elif required:
            raise SystemExit(f"Configuration file not found: {path}. Restore demo.config.env at the repository root.")
    if value is None:
        value = default
    if required and _missing(value):
        raise SystemExit(f"Missing setting {key} in demo.config.env. Fill it in (see the comments in that file).")
    return value
