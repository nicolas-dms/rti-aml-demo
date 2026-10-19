"""Probe the scoring endpoint and print the RESPONSE HEADERS.

Why a dedicated script: the whole blue/green dashboard rests on one assumption -
that a managed online endpoint tells us, in the "azureml-model-deployment"
response header, which deployment served the request. `az ml online-endpoint
invoke` hides the headers, so the assumption is untestable from the CLI. This
verifies it empirically before we build a dashboard tile on top of it.

It also doubles as an end-to-end check of the payload format and of the caller's
RBAC, using the same code path as the Function.

    pip install azure-identity requests
    python scripts/31_probe_endpoint.py --scoring-uri https://... 

The signed-in identity needs Microsoft.MachineLearningServices/workspaces/
onlineEndpoints/score/action on the workspace (built-in role: AzureML Data
Scientist).
"""

import argparse
import json
import os
import sys

import requests
from azure.identity import DefaultAzureCredential

SCORING_SCOPE = "https://ml.azure.com/.default"
DEFAULT_REQUEST = os.path.join("aml", "endpoints", "sample-request.json")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scoring-uri", required=True)
    parser.add_argument("--request-file", default=DEFAULT_REQUEST)
    parser.add_argument(
        "--deployment",
        default=None,
        help="Target a specific deployment (sent as the azureml-model-deployment "
        "REQUEST header). Leave empty to let the traffic split decide.",
    )
    args = parser.parse_args()

    with open(args.request_file, "r", encoding="utf-8") as handle:
        payload = json.load(handle)

    token = DefaultAzureCredential().get_token(SCORING_SCOPE).token
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    if args.deployment:
        headers["azureml-model-deployment"] = args.deployment

    response = requests.post(args.scoring_uri, json=payload, headers=headers, timeout=30)

    print(f"HTTP {response.status_code}\n")
    print("--- response headers ---")
    for key in sorted(response.headers):
        print(f"  {key}: {response.headers[key]}")

    served_by = response.headers.get("azureml-model-deployment")
    print("\n--- verdict ---")
    if served_by:
        print(f"  OK   served by deployment '{served_by}' - the dashboard tile is viable")
    else:
        print("  KO   no azureml-model-deployment header: the Function cannot label")
        print("       predictions by deployment. Fall back to an app setting and")
        print("       accept that it must be updated by hand during the swap.")

    print("\n--- body ---")
    print(response.text[:2000])

    return 0 if response.ok else 1


if __name__ == "__main__":
    sys.exit(main())
