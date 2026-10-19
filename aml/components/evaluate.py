"""Score the model on the held-out period and decide whether it deserves to ship.

The absolute MAE alone proves nothing. Temperature is autocorrelated, so simply
answering "in 15 minutes it will be exactly what it is now" already scores well.
That persistence baseline is computed here and the model has to beat it.
"""

import argparse
import glob
import json
import os

import mlflow
import numpy as np
import pandas as pd
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score

TARGET = "target_temperature_c"
NON_FEATURES = ["device_id", "minute", TARGET]


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model_input", type=str, required=True)
    parser.add_argument("--test_data", type=str, required=True)
    parser.add_argument("--max_mae", type=float, default=5.0)
    parser.add_argument("--evaluation_output", type=str, required=True)
    return parser.parse_args()


def load(folder):
    files = sorted(glob.glob(os.path.join(folder, "**", "*.parquet"), recursive=True))
    return pd.concat([pd.read_parquet(f) for f in files], ignore_index=True)


def main():
    args = parse_args()

    test = load(args.test_data)
    numeric = [c for c in test.columns if c not in NON_FEATURES]
    X = test[["device_id"] + numeric]
    y = test[TARGET]

    model = mlflow.sklearn.load_model(args.model_input)
    predictions = model.predict(X)

    mae = float(mean_absolute_error(y, predictions))
    rmse = float(np.sqrt(mean_squared_error(y, predictions)))
    r2 = float(r2_score(y, predictions))

    baseline_mae = float(mean_absolute_error(y, test["temperature_c"]))
    skill = float(1 - mae / baseline_mae) if baseline_mae else 0.0

    print(f"test rows    : {len(test):,}")
    print(f"MAE          : {mae:.4f}")
    print(f"RMSE         : {rmse:.4f}")
    print(f"R2           : {r2:.4f}")
    print(f"baseline MAE : {baseline_mae:.4f}  (persistence: t+15 == now)")
    print(f"skill        : {skill:+.1%} vs baseline")

    beats_baseline = mae < baseline_mae
    under_threshold = mae <= args.max_mae
    passed = bool(beats_baseline and under_threshold)

    for name, value in {
        "test_mae": mae,
        "test_rmse": rmse,
        "test_r2": r2,
        "baseline_mae": baseline_mae,
        "skill_vs_baseline": skill,
    }.items():
        mlflow.log_metric(name, value)

    metrics = {
        "mae": mae,
        "rmse": rmse,
        "r2": r2,
        "baseline_mae": baseline_mae,
        "skill_vs_baseline": skill,
        "max_mae": args.max_mae,
        "beats_baseline": beats_baseline,
        "under_threshold": under_threshold,
        "passed": passed,
        "n_test_rows": int(len(test)),
        "test_period_start": str(test["minute"].min()),
        "test_period_end": str(test["minute"].max()),
    }

    os.makedirs(args.evaluation_output, exist_ok=True)
    with open(os.path.join(args.evaluation_output, "metrics.json"), "w") as handle:
        json.dump(metrics, handle, indent=2)

    print(f"\ngate: {'PASS' if passed else 'FAIL'}")


if __name__ == "__main__":
    main()
