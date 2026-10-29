#!/usr/bin/env python3
"""Download the Roboflow disc model into the Android app's assets.

The app runs the disc-flight Workflow's detector on the device. Its weights
are 114 MB, over GitHub's file limit, so they are not committed: this script
fetches the ONNX package of the model the Workflow uses from Roboflow's
weights API (the one self-hosted Inference downloads from) and writes it to
disc_golf_android/app/src/main/assets/models/rfdetr/. Nothing is inferred,
so no credits are spent. Only the standard library is used.

    ROBOFLOW_API_KEY=... python scripts/fetch_disc_model.py

Run it again after retraining the model in Roboflow, with --model-id when
the Workflow's model_id input changes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path

# The default of the inner Workflow's (disc-golf-flight-tracker) model_id input.
MODEL_ID = "disc-golf-tracer/disc-golf-flight-tracker-2-rfdetr-small-t1"
API = "https://api.roboflow.com/models/v1/external/weights"
DEST = Path(__file__).resolve().parent.parent / "disc_golf_android/app/src/main/assets/models/rfdetr"
FILES = ("weights.onnx", "inference_config.json", "class_names.txt")
TIMEOUT_SECONDS = 120


def get_json(url: str, api_key: str) -> dict:
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {api_key}"})
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        return json.load(response)


def model_packages(model_id: str, api_key: str) -> list[dict]:
    packages, start_after = [], None
    for _ in range(10):
        query = {"modelId": model_id}
        if start_after:
            query["startAfter"] = start_after
        metadata = get_json(f"{API}?{urllib.parse.urlencode(query)}", api_key)["modelMetadata"]
        packages += metadata.get("modelPackages", [])
        start_after = metadata.get("nextPage")
        if not start_after:
            break
    return packages


def pick_onnx(packages: list[dict]) -> dict:
    """The full-precision ONNX package, which is what the Workflow runs on CPU."""
    onnx = [p for p in packages if p.get("packageManifest", {}).get("type") == "onnx-model-package-v1"]
    if not onnx:
        kinds = sorted({p.get("packageManifest", {}).get("type", "?") for p in packages})
        raise SystemExit(f"Roboflow has no ONNX package for this model, only: {', '.join(kinds)}")
    onnx.sort(key=lambda p: p["packageManifest"].get("quantization") != "fp32")
    return onnx[0]


def download(url: str, target: Path, md5: str | None) -> None:
    digest = hashlib.md5()
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as part:
        with urllib.request.urlopen(url, timeout=TIMEOUT_SECONDS) as response:
            while chunk := response.read(1 << 20):
                part.write(chunk)
                digest.update(chunk)
    if md5 and digest.hexdigest() != md5.lower():
        os.unlink(part.name)
        raise SystemExit(f"{target.name} failed its checksum; try again.")
    os.replace(part.name, target)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model-id", default=MODEL_ID)
    parser.add_argument("--dest", type=Path, default=DEST)
    args = parser.parse_args()
    api_key = os.environ.get("ROBOFLOW_API_KEY", "")
    if not api_key:
        raise SystemExit("Set ROBOFLOW_API_KEY to the Roboflow workspace's private API key.")

    package = pick_onnx(model_packages(args.model_id, api_key))
    files = {f["fileHandle"]: f for f in package["packageFiles"]}
    missing = [name for name in FILES if name not in files]
    if missing:
        raise SystemExit(f"The ONNX package has no {', '.join(missing)}.")
    args.dest.mkdir(parents=True, exist_ok=True)
    for name in FILES:
        download(files[name]["downloadUrl"], args.dest / name, files[name].get("md5Hash"))
        print(f"{name}: {(args.dest / name).stat().st_size} bytes")
    # Which package the app ships, so a rebuild can tell when it changed.
    (args.dest / "package.json").write_text(
        json.dumps(
            {"modelId": args.model_id, "packageId": package["packageId"], "manifest": package["packageManifest"]},
            indent=2,
        )
        + "\n"
    )
    print(f"Wrote {args.model_id} (package {package['packageId']}) to {args.dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
