"""Train the temperature forecaster and save it as an MLflow model."""

import argparse
import glob
import json
import os

import mlflow
import numpy as np
import pandas as pd
from mlflow.models import infer_signature
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.metrics import mean_absolute_error
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OrdinalEncoder

TARGET = "target_temperature_c"
NON_FEATURES = ["device_id", "minute", TARGET]


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--train_data", type=str, required=True)
    parser.add_argument("--model_output", type=str, required=True)
    parser.add_argument("--max_iter", type=int, default=400)
    parser.add_argument("--learning_rate", type=float, default=0.06)
    parser.add_argument("--max_leaf_nodes", type=int, default=31)
    return parser.parse_args()


def load(folder):
    files = sorted(glob.glob(os.path.join(folder, "**", "*.parquet"), recursive=True))
    return pd.concat([pd.read_parquet(f) for f in files], ignore_index=True)


def build_model(max_iter, learning_rate, max_leaf_nodes):
    # device_id is a real signal: each machine has its own thermal offset.
    # Unknown categories are encoded as NaN rather than -1 so that a machine
    # added later (P7) is treated as a missing value and degrades gracefully,
    # instead of raising at predict time on a negative category code.
    encoder = OrdinalEncoder(
        handle_unknown="use_encoded_value",
        unknown_value=np.nan,
        encoded_missing_value=np.nan,
    )
    pre = ColumnTransformer(
        [("device", encoder, ["device_id"])],
        remainder="passthrough",
        verbose_feature_names_out=False,
    )
    # Index 0 is the encoded device column produced by the transformer above.
    regressor = HistGradientBoostingRegressor(
        categorical_features=[0],
        max_iter=max_iter,
        learning_rate=learning_rate,
        max_leaf_nodes=max_leaf_nodes,
        early_stopping=True,
        validation_fraction=0.15,
        random_state=42,
    )
    return Pipeline([("pre", pre), ("model", regressor)])


def main():
    args = parse_args()

    train = load(args.train_data)
    numeric = [c for c in train.columns if c not in NON_FEATURES]
    feature_columns = ["device_id"] + numeric

    X = train[feature_columns]
    y = train[TARGET]

    # Widen narrow integers to int64 before fitting, so that the inferred
    # signature declares "long" rather than "integer".
    #
    # This is a serving concern, not a training one - the model itself is
    # indifferent. Every integer in a JSON request is parsed as int64 by pandas,
    # and MLflow's schema enforcement accepts widening conversions but refuses
    # narrowing ones. An int32 column in the signature is therefore unsatisfiable
    # over HTTP: the endpoint returns "Can not safely convert int64 to int32" on
    # every single request, and no client can work around it. Declaring int64
    # accepts both, since an int32 caller widens safely.
    narrow = X.select_dtypes(include=["int8", "int16", "int32"]).columns
    if len(narrow):
        print(f"widening to int64: {list(narrow)}")
        X = X.astype({column: "int64" for column in narrow})

    print(f"train rows: {len(X):,}")
    print(f"features  : {len(feature_columns)}")

    model = build_model(args.max_iter, args.learning_rate, args.max_leaf_nodes)
    model.fit(X, y)

    in_sample_mae = mean_absolute_error(y, model.predict(X))
    print(f"in-sample MAE: {in_sample_mae:.4f} (sanity only, real score comes from evaluate)")

    mlflow.log_params(
        {
            "max_iter": args.max_iter,
            "learning_rate": args.learning_rate,
            "max_leaf_nodes": args.max_leaf_nodes,
            "n_features": len(feature_columns),
            "n_train_rows": len(X),
        }
    )
    mlflow.log_metric("train_mae", in_sample_mae)

    signature = infer_signature(X, model.predict(X.head(5)))
    # extra_pip_requirements is not cosmetic: it is what makes the model
    # deployable at all.
    #
    # MLflow does NOT copy the training environment into the model. It infers a
    # much smaller set of requirements from the flavour - mlflow, scikit-learn,
    # numpy, pandas, cloudpickle - and setuptools is not in it. Azure ML then
    # rebuilds the serving container from THAT list. So the setuptools<81 pin we
    # added to rti-training-env fixes training and does nothing for serving:
    # mlflow 2.15.1 imports pkg_resources at module load, pkg_resources ships
    # with setuptools, setuptools 81 removed it, and the container dies on
    # "import mlflow" before it ever serves a request.
    #
    # Training environment and serving environment are two different artifacts.
    # Fixing one says nothing about the other.
    #
    # azureml-ai-monitoring is here for a less obvious reason. The scoring script
    # Azure ML generates for MLflow models does "from azureml.ai.monitoring
    # import Collector" at module level, UNCONDITIONALLY - whether or not data
    # collection is enabled. The curated MLflow inference images ship that
    # package; an environment built from this conda file does not, unless we say
    # so. By declaring our own dependencies we quietly took ownership of every
    # dependency of the serving container, including the ones in code we never
    # wrote. It is also the package P7b needs to turn model monitoring on.
    #
    # azureml-contrib-services is a consequence of the line above, not an
    # independent requirement. "azureml" is a namespace package. With none of
    # its sub-packages installed the inference server skips its
    # _patch_azureml_contrib_services() step; installing azureml-ai-monitoring
    # makes "azureml" resolvable while "azureml.contrib" still is not, so the
    # server now enters the patch and dies on the import. Half a namespace is
    # worse than none - a fix that creates the conditions for the next failure.
    #
    # azureml-defaults would supply both in one line and is the wrong answer: it
    # is the deprecated SDK v1, and it would re-pin numpy and pandas, reopening
    # the pyarrow/mlflow conflict already settled in rti-training-env.
    mlflow.sklearn.save_model(
        model,
        path=args.model_output,
        signature=signature,
        input_example=X.head(3),
        extra_pip_requirements=[
            "setuptools<81",
            "azureml-ai-monitoring",
            "azureml-contrib-services",
        ],
    )

    # The scoring Function (P6) builds its payload from a KQL query and must
    # send these columns, in this order. Shipping the list with the model means
    # the Function never has to hardcode it.
    with open(os.path.join(args.model_output, "feature_columns.json"), "w") as handle:
        json.dump(feature_columns, handle, indent=2)

    print(f"model saved to {args.model_output}")


if __name__ == "__main__":
    main()
