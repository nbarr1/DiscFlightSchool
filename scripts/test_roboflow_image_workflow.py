#!/usr/bin/env python3
"""Opt-in real image Workflow smoke test; never invoked by normal CI.

Sends one image through the published disc-detection Workflow, which spends
inference credits. Set ROBOFLOW_TEST_IMAGE to a local path or an https:// URL
of a throw frame. Without it, a synthetic frame (a white ellipse on green) is
generated: that proves the Workflow answers with its declared outputs, but
whether the ellipse is detected says nothing about accuracy on a real throw.
"""

from __future__ import annotations

import io
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))

from training_server.disc_detection import (  # noqa: E402
    PREDICTIONS_OUTPUT,
    parse_disc_detections,
    run_disc_detection_workflow,
)


def synthetic_frame() -> bytes:
    from PIL import Image, ImageDraw

    image = Image.new("RGB", (640, 360), (40, 120, 40))
    ImageDraw.Draw(image).ellipse((300, 150, 340, 172), fill=(245, 245, 245))
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG")
    return buffer.getvalue()


def main() -> None:
    key = os.environ.get("ROBOFLOW_API_KEY")
    if not key:
        raise SystemExit("Set ROBOFLOW_API_KEY to opt in")
    image = os.environ.get("ROBOFLOW_TEST_IMAGE") or synthetic_frame()

    outputs = run_disc_detection_workflow(image, api_key=key)
    block = outputs.get(PREDICTIONS_OUTPUT)
    if not isinstance(block, dict):
        raise SystemExit(f"Missing the '{PREDICTIONS_OUTPUT}' output; got {sorted(outputs)}")
    if not {"image", "predictions"} <= block.keys():
        raise SystemExit(f"'{PREDICTIONS_OUTPUT}' lacks image/predictions; got {sorted(block)}")

    result = parse_disc_detections(outputs)
    if result.image_width <= 0 or result.image_height <= 0:
        raise SystemExit("The Workflow reported an empty image size")
    print(
        f"Workflow outputs {sorted(outputs)}: {len(result.detections)} disc(s) "
        f"in a {result.image_width}x{result.image_height} image"
    )
    for box in result.detections:
        print(
            f"  {box.class_name} {box.confidence:.2f} at ({box.x:.0f}, {box.y:.0f}), "
            f"{box.width:.0f}x{box.height:.0f}"
        )


if __name__ == "__main__":
    main()
