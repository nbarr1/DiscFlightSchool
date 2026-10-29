#!/usr/bin/env python3
"""Download the Roboflow disc model for on-device use.

Reads the published flight-tracker Workflow, follows its inner Workflow to the
model it runs, and has the `inference` package download that model's files
into MODEL_CACHE_DIR, the way a self-hosted Inference server would. Nothing is
inferred, so no credits are spent.

    ROBOFLOW_API_KEY=... MODEL_CACHE_DIR=out python scripts/fetch_roboflow_model.py
"""

from __future__ import annotations

import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path

WORKSPACE = "disc-golf-tracer"
WORKFLOWS = ("disc-golf-flight-tracker-1789645514948", "disc-golf-flight-tracker")


def fetch_workflow(api_key: str, workflow_id: str) -> dict:
    query = urllib.parse.urlencode({"api_key": api_key})
    url = f"https://api.roboflow.com/{WORKSPACE}/workflows/{workflow_id}?{query}"
    with urllib.request.urlopen(url, timeout=60) as response:
        body = json.load(response)
    config = body["workflow"]["config"]
    return json.loads(config) if isinstance(config, str) else config


def model_ids(node, defaults: dict[str, object]) -> list[str]:
    """Every model_id in the spec, with `$inputs.x` resolved to the input's default."""
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "model_id" and isinstance(value, str):
                if value.startswith("$inputs."):
                    value = defaults.get(value.removeprefix("$inputs."), value)
                found.append(str(value))
            else:
                found += model_ids(value, defaults)
    elif isinstance(node, list):
        for value in node:
            found += model_ids(value, defaults)
    return found


def main() -> int:
    api_key = os.environ["ROBOFLOW_API_KEY"]
    out = Path(os.environ.get("MODEL_CACHE_DIR", "roboflow-model"))
    out.mkdir(parents=True, exist_ok=True)
    ids: list[str] = []
    for workflow_id in WORKFLOWS:
        spec = fetch_workflow(api_key, workflow_id)
        (out / f"workflow-{workflow_id}.json").write_text(json.dumps(spec, indent=2))
        print(f"Workflow {workflow_id}:")
        print(json.dumps(spec, indent=2))
        definition = spec.get("specification", spec)
        defaults = {
            item["name"]: item["default_value"]
            for item in definition.get("inputs", [])
            if "default_value" in item
        }
        ids += model_ids(spec, defaults)
    ids = sorted(set(ids))
    print("Model IDs:", ids)

    from inference import get_model

    for model_id in ids:
        if model_id.startswith("$"):
            continue
        model = get_model(model_id=model_id, api_key=api_key)
        print(f"Loaded {model_id}: {type(model).__name__}")
        for attribute in ("cache_dir", "model_path", "onnx_path"):
            if hasattr(model, attribute):
                print(f"  {attribute} = {getattr(model, attribute)}")
    for path in sorted(out.rglob("*")):
        if path.is_file():
            print(f"{path} ({path.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
