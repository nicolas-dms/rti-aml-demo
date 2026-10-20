"""Track C / M2 (R-12) - register the frozen snapshot as data asset telemetry_train:<snapshot_id>.

Reads ml/training/site=<site>/snapshot=<snapshot_id>/_manifest.json through the AML
datastore's storage account, hashes the manifest bytes (the same SHA-256 that
aml/components/prep.py verifies) and registers a uri_folder asset with exactly 7 tags:
site, window_start, window_end, row_count, manifest_sha256, source_table,
source_delta_version.

Immutable and idempotent:
  * asset version absent           -> create it, re-read it, check the tags      (exit 0)
  * present, same sha256, 7 tags OK -> report, change nothing                    (exit 0)
  * present, same sha256, tags off  -> report the differences, change nothing    (exit 3)
  * present, different sha256      -> report the conflict, change nothing        (exit 2)

window_start / window_end tags are '<manifest ISO>UTC' (AML rewrites plain ISO dates).

Auth: DefaultAzureCredential only (az login locally, the service connection in CI).
No key, no SAS, no secret. The identity needs read on the datastore's storage
(Storage Blob Data Reader or Contributor) and AzureML Data Scientist on the DEV workspace.

Requires: azure-ai-ml, azure-identity, azure-storage-file-datalake.
"""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import demo_config  # noqa: E402  (reads demo.config.env)

from azure.ai.ml import MLClient
from azure.ai.ml.constants import AssetTypes
from azure.ai.ml.entities import Data
from azure.core.exceptions import ResourceNotFoundError
from azure.identity import DefaultAzureCredential
from azure.storage.filedatalake import DataLakeServiceClient

SUBSCRIPTION_ID = demo_config.get("AZURE_SUBSCRIPTION_ID", required=True)
RESOURCE_GROUP = demo_config.get("AZURE_RESOURCE_GROUP", required=True)
WORKSPACE = demo_config.get("AML_DEV_WORKSPACE", required=True)
DATASTORE = demo_config.get("AML_DATASTORE", "rti_snapshots")
ASSET_NAME = "telemetry_train"
MANIFEST_NAME = "_manifest.json"
SNAPSHOT_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
NAIVE_ISO_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$")
REQUIRED_MANIFEST_KEYS = (
    "site", "snapshot_id", "data_file", "data_sha256", "row_count",
    "window_start", "window_end", "columns", "source_table", "source_delta_version",
)


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--snapshot-id", required=True)
    parser.add_argument("--site", default="demo")
    parser.add_argument("--datastore", default=DATASTORE)
    parser.add_argument("--subscription-id", default=SUBSCRIPTION_ID)
    parser.add_argument("--resource-group", default=RESOURCE_GROUP)
    parser.add_argument("--workspace", default=WORKSPACE)
    return parser.parse_args()


def fail(message, code=1):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(code)


def utc_tag(value, label):
    """Manifest timestamp (naive UTC ISO) -> tag value '<iso>UTC'.

    Measured on 2026-10-13: AML rewrites any tag value it can parse as a date
    ('2026-10-12T13:20:00' and '...Z' both came back as '10/12/2026 13:20:00', month first,
    ambiguous). '2026-10-12T13:20:00UTC' is stored untouched, and says the zone out loud.
    """
    text = str(value)
    if not NAIVE_ISO_PATTERN.match(text):
        fail(f"manifest {label} {text!r} is not a naive ISO timestamp (YYYY-MM-DDTHH:MM:SS)")
    return f"{text}UTC"


def main():
    args = parse_args()
    if not SNAPSHOT_ID_PATTERN.match(args.snapshot_id):
        fail(f"snapshot id {args.snapshot_id!r} is not a valid version (letters, digits, . _ -)")

    credential = DefaultAzureCredential()
    ml_client = MLClient(credential, args.subscription_id, args.resource_group, args.workspace)

    datastore = ml_client.datastores.get(args.datastore)
    account = getattr(datastore, "account_name", None)
    filesystem = getattr(datastore, "filesystem", None)
    if not account or not filesystem:
        fail(f"datastore {args.datastore} has no account_name/filesystem: not an ADLS Gen2 datastore")

    folder = f"ml/training/site={args.site}/snapshot={args.snapshot_id}"
    service = DataLakeServiceClient(f"https://{account}.dfs.core.windows.net", credential=credential)
    file_system = service.get_file_system_client(filesystem)

    try:
        manifest_bytes = file_system.get_file_client(f"{folder}/{MANIFEST_NAME}").download_file().readall()
    except ResourceNotFoundError:
        fail(f"{MANIFEST_NAME} not found under {filesystem}/{folder}: snapshot absent or incomplete "
             "(the manifest is written last)")
    manifest_sha256 = hashlib.sha256(manifest_bytes).hexdigest()
    manifest = json.loads(manifest_bytes.decode("utf-8"))

    missing = [key for key in REQUIRED_MANIFEST_KEYS if key not in manifest]
    if missing:
        fail(f"manifest lacks required keys: {missing}")
    if manifest["snapshot_id"] != args.snapshot_id or manifest["site"] != args.site:
        fail(f"manifest says site={manifest['site']!r} snapshot_id={manifest['snapshot_id']!r}, "
             f"which does not match the folder site={args.site!r} snapshot={args.snapshot_id!r}")

    # The folder must hold exactly the declared data file + the manifest, nothing else.
    present = sorted(
        path.name[len(folder) + 1:]
        for path in file_system.get_paths(path=folder, recursive=True)
        if not path.is_directory
    )
    expected = sorted([manifest["data_file"], MANIFEST_NAME])
    if present != expected:
        fail(f"snapshot folder content {present} differs from the manifest's {expected}")

    tags = {
        "site": str(manifest["site"]),
        "window_start": utc_tag(manifest["window_start"], "window_start"),
        "window_end": utc_tag(manifest["window_end"], "window_end"),
        "row_count": str(manifest["row_count"]),
        "manifest_sha256": manifest_sha256,
        "source_table": str(manifest["source_table"]),
        "source_delta_version": str(manifest["source_delta_version"]),
    }

    try:
        versions = [d for d in ml_client.data.list(name=ASSET_NAME) if str(d.version) == args.snapshot_id]
    except ResourceNotFoundError:
        versions = []

    if versions:
        existing = versions[0]
        existing_sha = (existing.tags or {}).get("manifest_sha256")
        if existing_sha == manifest_sha256:
            existing_tags = dict(existing.tags or {})
            if existing_tags != tags:
                diff = {k: {"expected": tags.get(k), "found": existing_tags.get(k)}
                        for k in sorted(set(tags) | set(existing_tags)) if tags.get(k) != existing_tags.get(k)}
                print(f"TAGS DIFFER: {ASSET_NAME}:{args.snapshot_id} has the right manifest_sha256 but its tags "
                      f"are not the expected 7: {json.dumps(diff, indent=2)}", file=sys.stderr)
                print("Tags are mutable: fix them with 'az ml data update --set tags.<key>=<value>'. "
                      "Nothing changed by this script.", file=sys.stderr)
                return 3
            print(f"{ASSET_NAME}:{args.snapshot_id} already exists with the same manifest_sha256 and the 7 expected "
                  "tags; nothing created.")
            print(json.dumps({"asset": f"{ASSET_NAME}:{args.snapshot_id}", "state": "already-present",
                              "manifest_sha256": manifest_sha256}, indent=2))
            return 0
        print(f"CONFLICT: {ASSET_NAME}:{args.snapshot_id} exists with manifest_sha256={existing_sha!r}, "
              f"the snapshot on storage has {manifest_sha256!r}. Versions are immutable: nothing changed. "
              "Use a new snapshot id.", file=sys.stderr)
        return 2

    asset = Data(
        name=ASSET_NAME,
        version=args.snapshot_id,
        type=AssetTypes.URI_FOLDER,
        path=f"azureml://datastores/{args.datastore}/paths/{folder}/",
        description=f"Frozen training snapshot {args.snapshot_id} (site {args.site}); verified by manifest.",
        tags=tags,
    )
    ml_client.data.create_or_update(asset)

    created = ml_client.data.get(ASSET_NAME, version=args.snapshot_id)
    if (created.tags or {}) != tags:
        fail(f"asset created but its tags differ from the expected 7: {created.tags}")
    print(json.dumps({"asset": f"{ASSET_NAME}:{args.snapshot_id}", "state": "created",
                      "path": created.path, "tags": created.tags}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
