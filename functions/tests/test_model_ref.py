"""R-62: the Function must read name and version from workspace AND registry references.

Run from the functions/ folder:  python -m pytest tests -q
Skipped if the Azure SDK packages of the Function are not installed.
"""
import os
import sys

import pytest

pytest.importorskip("azure.functions")
pytest.importorskip("azure.kusto.data")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import function_app  # noqa: E402


@pytest.mark.parametrize(
    "reference, expected",
    [
        (
            "azureml://registries/mlr-rti-demo/models/temp_forecaster/versions/8",
            ("temp_forecaster", "8"),
        ),
        (
            "/subscriptions/s/resourceGroups/rg/providers/Microsoft.MachineLearningServices"
            "/workspaces/aml-rti-demo/models/temp_forecaster/versions/6",
            ("temp_forecaster", "6"),
        ),
        (
            "azureml://registries/mlr-rti-demo/models/temp_forecaster/versions/12?x=1",
            ("temp_forecaster", "12"),
        ),
    ],
)
def test_model_reference_is_parsed(reference, expected):
    match = function_app.MODEL_REF_RE.search(reference)
    assert match is not None
    assert (match.group(1), match.group(2)) == expected


def test_ttl_setting_falls_back_to_default(monkeypatch):
    monkeypatch.setenv("TTL_TEST", "not-a-number")
    assert function_app._int_setting("TTL_TEST", 600) == 600
    monkeypatch.setenv("TTL_TEST", "60")
    assert function_app._int_setting("TTL_TEST", 600) == 60
    monkeypatch.delenv("TTL_TEST")
    assert function_app._int_setting("TTL_TEST", 600) == 600
