"""Register the model in the AML registry, but only if the gate passed."""

import argparse
import json
import os

import mlflow
from mlflow.tracking import MlflowClient


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model_input", type=str, required=True)
    parser.add_argument("--evaluation_output", type=str, required=True)
    parser.add_argument("--model_name", type=str, default="temp_forecaster")
    parser.add_argument("--data_asset", type=str, default="telemetry_features:1")
    # Track C lineage. All optional: a track A run leaves them at their defaults.
    parser.add_argument("--git_sha", type=str, default="local")
    parser.add_argument("--ado_build_id", type=str, default="local")
    parser.add_argument("--data_manifest_sha256", type=str, default="")
    return parser.parse_args()


def main():
    args = parse_args()

    with open(os.path.join(args.evaluation_output, "metrics.json")) as handle:
        metrics = json.load(handle)

    if not metrics["passed"]:
        raise RuntimeError(
            "Gate failed, nothing registered. "
            f"MAE {metrics['mae']:.4f} vs threshold {metrics['max_mae']} "
            f"and baseline {metrics['baseline_mae']:.4f}. "
            "A model that does not beat persistence has no business being deployed."
        )

    # Register the directory train.py produced, byte for byte.
    #
    # The obvious version of this component was:
    #     model = mlflow.sklearn.load_model(args.model_input)
    #     mlflow.sklearn.log_model(model, ..., registered_model_name=...)
    # and it is wrong in a way that costs hours. Loading and re-logging does not
    # move the model, it MANUFACTURES A NEW ONE: MLflow re-serialises the object
    # and re-infers a conda.yaml from the flavour alone. Everything train.py
    # declared is silently discarded - the signature, the input_example, and the
    # extra_pip_requirements pin that makes the model deployable at all. The
    # serving container then dies on "import mlflow" for lack of setuptools,
    # several steps away from the line that caused it.
    #
    # log_artifacts + register_model uploads the folder as-is, so what gets
    # deployed is exactly what training produced. It also removes a second,
    # quieter risk: re-serialising with the register step's own sklearn and
    # cloudpickle versions rather than the ones training used.
    run = mlflow.active_run() or mlflow.start_run()
    mlflow.log_artifacts(args.model_input, artifact_path=args.model_name)
    mlflow.register_model(f"runs:/{run.info.run_id}/{args.model_name}", args.model_name)

    client = MlflowClient()
    versions = client.search_model_versions(f"name='{args.model_name}'")
    latest = max(versions, key=lambda v: int(v.version))
    print(f"registered {args.model_name} version {latest.version}")

    tags = {
        "data_asset": args.data_asset,
        "mae": f"{metrics['mae']:.4f}",
        "rmse": f"{metrics['rmse']:.4f}",
        "baseline_mae": f"{metrics['baseline_mae']:.4f}",
        "skill_vs_baseline": f"{metrics['skill_vs_baseline']:.4f}",
        "test_period_end": metrics["test_period_end"],
        "git_sha": args.git_sha,
        "ado_build_id": args.ado_build_id,
    }
    if args.data_manifest_sha256.strip():
        tags["data_manifest_sha256"] = args.data_manifest_sha256.strip().lower()
    # Tagging is a convenience, not the deliverable. If the backing registry
    # rejects it, the model is already registered and the job should not fail.
    for key, value in tags.items():
        try:
            client.set_model_version_tag(args.model_name, latest.version, key, value)
        except Exception as error:  # noqa: BLE001
            print(f"WARNING: could not set tag {key}: {error}")

    print(json.dumps({"model_name": args.model_name, "version": latest.version, **tags}, indent=2))


if __name__ == "__main__":
    main()
