"""Split the snapshot into train / test along the TIME axis.

A random split would be silently wrong here. Every row carries lag features
computed from its own past and a label read 15 minutes into its future, so
shuffling lets the model see the answer through neighbouring rows and produces
an excellent score for a model that cannot forecast anything.
"""

import argparse
import glob
import hashlib
import json
import os

import pandas as pd

TARGET = "target_temperature_c"
MANIFEST_NAME = "_manifest.json"


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input_folder", type=str, required=True)
    parser.add_argument("--test_fraction", type=float, default=0.2)
    parser.add_argument("--embargo_min", type=int, default=15)
    # Optional: absent => track A behaviour, nothing is verified.
    parser.add_argument("--expected_manifest_sha256", type=str, default="")
    parser.add_argument("--train_data", type=str, required=True)
    parser.add_argument("--test_data", type=str, required=True)
    return parser.parse_args()


class SnapshotVerificationError(RuntimeError):
    pass


def _fail(what, expected, actual):
    raise SnapshotVerificationError(
        f"SNAPSHOT VERIFICATION FAILED - {what}: expected {expected!r}, found {actual!r}. "
        "Nothing was trained."
    )


def _sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _naive_utc(value):
    stamp = pd.Timestamp(value)
    if stamp.tzinfo is not None:
        stamp = stamp.tz_convert("UTC").tz_localize(None)
    return stamp


def verify_snapshot(folder, expected_manifest_sha256):
    """Check the frozen snapshot against its manifest. Raises before any training.

    The manifest hash is taken over the file bytes as written (the notebook
    serialises canonically), so the same snapshot always gives the same hash.
    """
    expected_manifest_sha256 = expected_manifest_sha256.strip().lower()

    manifest_path = os.path.join(folder, MANIFEST_NAME)
    if not os.path.isfile(manifest_path):
        _fail("manifest presence", MANIFEST_NAME, "absent (snapshot incomplete or not a snapshot)")

    manifest_sha256 = _sha256_file(manifest_path)
    if manifest_sha256 != expected_manifest_sha256:
        _fail("manifest SHA-256", expected_manifest_sha256, manifest_sha256)

    with open(manifest_path, "r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    for key in ("data_file", "data_sha256", "row_count", "columns", "window_start", "window_end"):
        if key not in manifest:
            _fail("manifest key", key, "missing")

    # Every file except the manifest is data; only the declared one may exist.
    present = sorted(
        os.path.relpath(os.path.join(root, name), folder).replace(os.sep, "/")
        for root, _, names in os.walk(folder)
        for name in names
        if not (root == folder and name == MANIFEST_NAME)
    )
    if present != [manifest["data_file"]]:
        _fail("data files", [manifest["data_file"]], present)

    data_path = os.path.join(folder, manifest["data_file"])
    data_sha256 = _sha256_file(data_path)
    if data_sha256 != manifest["data_sha256"]:
        _fail(f"SHA-256 of {manifest['data_file']}", manifest["data_sha256"], data_sha256)

    frame = pd.read_parquet(data_path)
    if len(frame) != manifest["row_count"]:
        _fail("row count", manifest["row_count"], len(frame))
    if list(frame.columns) != list(manifest["columns"]):
        _fail("columns", list(manifest["columns"]), list(frame.columns))
    minutes = pd.to_datetime(frame["minute"])
    for label, actual in (("window_start", minutes.min()), ("window_end", minutes.max())):
        if _naive_utc(manifest[label]) != _naive_utc(actual):
            _fail(label, manifest[label], str(actual))

    print(
        f"snapshot verified: manifest {manifest_sha256[:12]}..., {manifest['data_file']} "
        f"{data_sha256[:12]}..., {len(frame):,} rows, "
        f"{manifest['window_start']} -> {manifest['window_end']}"
    )


def load_snapshot(folder):
    files = sorted(glob.glob(os.path.join(folder, "**", "*.parquet"), recursive=True))
    if not files:
        raise RuntimeError(f"No parquet file found under {folder}")
    print(f"parquet files: {len(files)}")
    frame = pd.concat([pd.read_parquet(f) for f in files], ignore_index=True)
    frame["minute"] = pd.to_datetime(frame["minute"])
    return frame.sort_values(["minute", "device_id"]).reset_index(drop=True)


def main():
    args = parse_args()

    if args.expected_manifest_sha256.strip():
        verify_snapshot(args.input_folder, args.expected_manifest_sha256)
    else:
        print("no expected_manifest_sha256 given: snapshot NOT verified (track A behaviour)")

    df = load_snapshot(args.input_folder)
    print(f"rows   : {len(df):,}")
    print(f"columns: {len(df.columns)}")
    print(f"period : {df['minute'].min()} -> {df['minute'].max()}")

    if TARGET not in df.columns:
        raise RuntimeError(f"Column {TARGET} is missing; columns are {list(df.columns)}")
    missing = int(df.isna().sum().sum())
    if missing:
        raise RuntimeError(f"{missing} missing values; the notebook should have dropped them")

    minutes = df["minute"].drop_duplicates().sort_values().reset_index(drop=True)
    cutoff = minutes.iloc[int(len(minutes) * (1 - args.test_fraction))]

    # A training row at time t is labelled with the temperature at t + horizon.
    # Rows closer than that to the cutoff would be labelled with values taken
    # from the test period, so they are dropped rather than leaked.
    train_end = cutoff - pd.Timedelta(minutes=args.embargo_min)
    train = df[df["minute"] < train_end]
    test = df[df["minute"] >= cutoff]

    print(f"\ncutoff    : {cutoff}")
    print(f"embargo   : {args.embargo_min} min -> train stops at {train_end}")
    print(f"train rows: {len(train):,}  ({train['minute'].min()} -> {train['minute'].max()})")
    print(f"test rows : {len(test):,}  ({test['minute'].min()} -> {test['minute'].max()})")

    if train.empty or test.empty:
        raise RuntimeError("Empty split: the snapshot is too short for this test_fraction")

    os.makedirs(args.train_data, exist_ok=True)
    os.makedirs(args.test_data, exist_ok=True)
    train.to_parquet(os.path.join(args.train_data, "data.parquet"), index=False)
    test.to_parquet(os.path.join(args.test_data, "data.parquet"), index=False)


if __name__ == "__main__":
    main()
