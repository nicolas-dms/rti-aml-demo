"""P6 - the scoring loop.

Every 30 seconds this Function does four things:

    features_now()  ->  POST to the AML endpoint  ->  read who answered  ->  write back

The 30-second cadence is not about freshness (the features are minute-grained
anyway); it is about the demo. During the blue/green swap in P7 the dashboard
must visibly change colour within a few seconds, not on the next minute.

Three design points worth stating explicitly, because each one is a place where
this kind of code usually goes quietly wrong:

1. The Function does NOT build features. It calls features_now(), a stored
   function in the Eventhouse that mirrors the PySpark feature engineering of
   the training notebook. Defining them twice is how training/serving skew is
   born - and skew never raises an error, it just degrades predictions.

2. The Function never learns which model it is talking to. It posts to one
   scoring URI and reads the "azureml-model-deployment" response header to
   find out who answered. That is the whole point of the blue/green demo: the
   caller is untouched while the model behind the URI changes.

3. Predictions are written with the Kusto ingest client, not with a
   ".set-or-append <| datatable(...)" built by string concatenation. Values
   coming back from the model and from ARM are treated as data, never as
   query text.
"""

import datetime
import io
import json
import logging
import os
import re
import threading
import time

import azure.functions as func
import requests
from azure.identity import DefaultAzureCredential
from azure.kusto.data import KustoClient, KustoConnectionStringBuilder

# DataFormat lives in azure.kusto.DATA, not azure.kusto.ingest, even though it
# is only ever used to configure an ingestion. azure-kusto-ingest imports it
# from here itself, and every sample in the library does the same. Importing it
# from azure.kusto.ingest raises ImportError at module load, which the Functions
# worker reports as "0 functions found" - a message that says nothing about the
# real cause.
from azure.kusto.data.data_format import DataFormat
from azure.kusto.ingest import IngestionProperties, QueuedIngestClient

app = func.FunctionApp()

# ---------------------------------------------------------------------------
# Contract with the model.
#
# This is the column list produced by aml/components/train.py (which also ships
# it as feature_columns.json inside the model). MLflow reorders a named
# DataFrame to match the signature, so the order below is documentation rather
# than a hard requirement - but a MISSING or MISSPELLED name is a hard failure,
# which is exactly what we want: loud, not silent.
# ---------------------------------------------------------------------------
FEATURE_COLUMNS = [
    "device_id",
    "temperature_c",
    "humidity_pct",
    "pressure_bar",
    "vibration_mm_s",
    "temperature_c_lag1",
    "temperature_c_lag5",
    "temperature_c_lag15",
    "humidity_pct_lag1",
    "humidity_pct_lag5",
    "humidity_pct_lag15",
    "pressure_bar_lag1",
    "pressure_bar_lag5",
    "pressure_bar_lag15",
    "vibration_mm_s_lag1",
    "vibration_mm_s_lag5",
    "vibration_mm_s_lag15",
    "temperature_c_mean30",
    "temperature_c_std30",
    "vibration_mm_s_mean30",
    "vibration_mm_s_std30",
    "temperature_slope15",
    "hour_of_day",
]

SCORING_SCOPE = "https://ml.azure.com/.default"
ARM_SCOPE = "https://management.azure.com/.default"
ARM_API_VERSION = "2024-04-01"

# Track C: the colour behind a deployment name can be recreated with a new
# model version; a long cache would keep the old label for that long. Default
# stays 600 (track A behaviour); set DEPLOYMENT_CACHE_TTL_SEC=60 for track C.
def _int_setting(name, default):
    try:
        return max(0, int(os.environ.get(name, default)))
    except (TypeError, ValueError):
        return default


DEPLOYMENT_CACHE_TTL_SEC = _int_setting("DEPLOYMENT_CACHE_TTL_SEC", 600)

# Works for workspace (azureml:...) and registry (azureml://registries/...) models.
MODEL_REF_RE = re.compile(r"/models/([^/]+)/versions/([^/?]+)")


def setting(name, default=None):
    value = os.environ.get(name, default)
    if value is None:
        raise RuntimeError(f"Missing app setting: {name}")
    return value


# ---------------------------------------------------------------------------
# Credentials and clients - built once per worker, not once per invocation.
#
# RLock, NOT Lock. kusto() and ingest() hold this lock and then call
# credential(), which takes it again on the same thread. A plain
# threading.Lock is not reentrant, so that second acquisition waits forever on
# a lock the thread already owns. The function then hangs with ZERO log output
# until the platform kills it at the 30 minute timeout - which looks exactly
# like a network or RBAC problem and is neither.
# ---------------------------------------------------------------------------
_lock = threading.RLock()
_credential = None
_kusto = None
_ingest = None
_tokens = {}
_deployments = {}


def credential():
    global _credential
    with _lock:
        if _credential is None:
            _credential = DefaultAzureCredential()
        return _credential


def bearer(scope):
    """Cached token. Refreshed five minutes before expiry."""
    with _lock:
        cached = _tokens.get(scope)
        if cached and cached[1] - time.time() > 300:
            return cached[0]
    token = credential().get_token(scope)
    with _lock:
        _tokens[scope] = (token.token, token.expires_on)
    return token.token


def kusto():
    global _kusto
    with _lock:
        if _kusto is None:
            kcsb = KustoConnectionStringBuilder.with_azure_token_credential(
                setting("KUSTO_CLUSTER_URI"), credential()
            )
            _kusto = KustoClient(kcsb)
        return _kusto


def ingest():
    global _ingest
    with _lock:
        if _ingest is None:
            kcsb = KustoConnectionStringBuilder.with_azure_token_credential(
                setting("KUSTO_INGEST_URI"), credential()
            )
            _ingest = QueuedIngestClient(kcsb)
        return _ingest


# ---------------------------------------------------------------------------
# Step 1 - read the features
# ---------------------------------------------------------------------------
def read_features():
    """One row per device, straight out of the database. No maths here."""
    result = kusto().execute(setting("KUSTO_DATABASE"), "features_now()")
    return [row.to_dict() for row in result.primary_results[0]]


def drop_stale(rows, max_age_sec):
    """A prediction built on old features is worse than no prediction: it looks
    fine on the dashboard and is wrong. If the simulator stops, we stop too."""
    now = datetime.datetime.now(datetime.timezone.utc)
    fresh, stale = [], []
    for row in rows:
        t0 = row["t0"]
        if t0.tzinfo is None:
            t0 = t0.replace(tzinfo=datetime.timezone.utc)
        age = (now - t0).total_seconds()
        (fresh if age <= max_age_sec else stale).append((row, age))
    if stale:
        detail = ", ".join(f"{r['device_id']}={a:.0f}s" for r, a in stale)
        logging.warning("skipping %d device(s) with stale features: %s", len(stale), detail)
    return [r for r, _ in fresh]


# ---------------------------------------------------------------------------
# Step 2 - score
# ---------------------------------------------------------------------------
def score(rows):
    """POST the batch and return (predictions, deployment_name).

    Payload shape is the MLflow "split" orientation that AML expects:
    {"input_data": {"columns": [...], "data": [[...]], "index": [...]}}.
    Note "input_data", not "inputs" - the latter is native MLflow serving and
    is rejected here.
    """
    payload = {
        "input_data": {
            "columns": FEATURE_COLUMNS,
            "data": [[row[c] for c in FEATURE_COLUMNS] for row in rows],
            "index": list(range(len(rows))),
        }
    }
    response = requests.post(
        setting("AML_SCORING_URI"),
        json=payload,
        headers={
            "Authorization": f"Bearer {bearer(SCORING_SCOPE)}",
            "Content-Type": "application/json",
        },
        timeout=20,
    )
    response.raise_for_status()

    # The deployment that actually served the request. This is the column the
    # blue/green tile is built on.
    deployment = response.headers.get("azureml-model-deployment")
    if not deployment:
        logging.warning(
            "no azureml-model-deployment response header; headers were: %s",
            sorted(response.headers.keys()),
        )
        deployment = "unknown"

    body = response.json()
    predictions = body.get("predictions", body) if isinstance(body, dict) else body
    if len(predictions) != len(rows):
        raise RuntimeError(f"expected {len(rows)} predictions, got {len(predictions)}")
    return predictions, deployment


# ---------------------------------------------------------------------------
# Step 3 - which model is behind that deployment?
#
# The scoring response tells us the deployment name, not the model version. We
# resolve it against ARM and cache it. Doing it this way rather than hardcoding
# "blue = v1, green = v2" in app settings means the demo cannot drift: when
# green is created in P7, the Function discovers v2 by itself.
# ---------------------------------------------------------------------------
def resolve_model(deployment):
    if deployment == "unknown":
        return "unknown", "unknown"

    with _lock:
        cached = _deployments.get(deployment)
        if cached and time.time() - cached[2] < DEPLOYMENT_CACHE_TTL_SEC:
            return cached[0], cached[1]

    url = (
        "https://management.azure.com"
        f"/subscriptions/{setting('AML_SUBSCRIPTION_ID')}"
        f"/resourceGroups/{setting('AML_RESOURCE_GROUP')}"
        "/providers/Microsoft.MachineLearningServices"
        f"/workspaces/{setting('AML_WORKSPACE')}"
        f"/onlineEndpoints/{setting('AML_ENDPOINT_NAME')}"
        f"/deployments/{deployment}"
        f"?api-version={ARM_API_VERSION}"
    )
    try:
        response = requests.get(
            url, headers={"Authorization": f"Bearer {bearer(ARM_SCOPE)}"}, timeout=15
        )
        response.raise_for_status()
        asset = response.json()["properties"]["model"]
        match = MODEL_REF_RE.search(asset)
        if not match:
            raise RuntimeError(f"unrecognised model reference: {asset}")
        name, version = match.group(1), match.group(2)
    except Exception as error:  # noqa: BLE001 - never let this break the loop
        logging.warning("could not resolve model behind '%s': %s", deployment, error)
        return "unknown", "unknown"

    with _lock:
        _deployments[deployment] = (name, version, time.time())
    return name, version


# ---------------------------------------------------------------------------
# Step 4 - write back
# ---------------------------------------------------------------------------
def write_back(rows, predictions, deployment, model_name, model_version, horizon_min):
    """scored_at is the FEATURE timestamp t0, not the wall clock.

    That is deliberate: t0 is minute-aligned, so "scored_at + 15m" lands exactly
    on a telemetry minute bin and the observed-MAE query joins without any
    rounding. A wall-clock timestamp at :17s would join onto nothing.
    """
    records = []
    for row, prediction in zip(rows, predictions):
        records.append(
            {
                "scored_at": row["t0"].isoformat(),
                "device_id": row["device_id"],
                "horizon_min": horizon_min,
                "predicted_temperature_c": float(prediction),
                "model_name": model_name,
                "model_version": model_version,
                "deployment": deployment,
            }
        )

    properties = IngestionProperties(
        database=setting("KUSTO_DATABASE"),
        table="scoring_results",
        data_format=DataFormat.JSON,
        ingestion_mapping_reference="scoring_results_mapping",
    )
    stream = io.BytesIO("\n".join(json.dumps(r) for r in records).encode("utf-8"))
    ingest().ingest_from_stream(stream, ingestion_properties=properties)
    return len(records)


# ---------------------------------------------------------------------------
# The loop itself
# ---------------------------------------------------------------------------
@app.function_name(name="score_timer")
@app.timer_trigger(
    schedule="0/30 * * * * *",
    arg_name="timer",
    run_on_startup=False,
    use_monitor=False,
)
def score_timer(timer: func.TimerRequest) -> None:
    started = time.time()

    # Stage markers. Without them, a hang is indistinguishable from work in
    # progress: the summary line below only prints on success, so a blocked
    # invocation produced no output at all and told us nothing about WHERE it
    # was blocked. That cost us the RLock deadlock hunt.
    logging.info("score_timer: start")

    rows = read_features()
    logging.info("score_timer: features read (%d row(s), %.2fs)", len(rows), time.time() - started)
    if not rows:
        logging.warning("features_now() returned nothing - is the simulator running?")
        return

    rows = drop_stale(rows, int(setting("MAX_STALENESS_SEC", "180")))
    if not rows:
        logging.warning("every device is stale, nothing scored")
        return

    predictions, deployment = score(rows)
    logging.info("score_timer: scored by '%s' (%.2fs)", deployment, time.time() - started)

    model_name, model_version = resolve_model(deployment)
    horizon_min = int(setting("HORIZON_MIN", "15"))
    written = write_back(rows, predictions, deployment, model_name, model_version, horizon_min)

    logging.info(
        "scored %d device(s) via '%s' (%s:%s) in %.2fs - t0=%s",
        written,
        deployment,
        model_name,
        model_version,
        time.time() - started,
        rows[0]["t0"].isoformat(),
    )
