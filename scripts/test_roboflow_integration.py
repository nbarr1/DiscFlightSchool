#!/usr/bin/env python3
"""Opt-in real Workflow smoke test; never invoked by normal CI."""

from __future__ import annotations

import os
import sys
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))

from training_server.config import Settings  # noqa: E402
from training_server.disc_flight import RoboflowVideoProcessor  # noqa: E402


def main() -> None:
    key = os.environ.get("ROBOFLOW_API_KEY")
    source_name = os.environ.get("ROBOFLOW_TEST_VIDEO")
    if not key or not source_name:
        raise SystemExit("Set ROBOFLOW_API_KEY and ROBOFLOW_TEST_VIDEO to opt in")
    source = Path(source_name)
    if not source.is_file():
        raise SystemExit(f"Test video does not exist: {source}")
    destination = Path(os.environ.get("ROBOFLOW_TEST_OUTPUT", "/tmp/disc-flight-annotated.mp4"))
    settings = Settings(app_api_key="integration-only", base_dir=ROOT / "server", roboflow_api_key=key)
    summary = RoboflowVideoProcessor(settings)(
        source,
        destination,
        threading.Event(),
        lambda done, total, status: print(f"{status}: {done}/{total or '?'}"),
    )
    import cv2

    capture = cv2.VideoCapture(str(destination))
    playable = capture.isOpened() and int(capture.get(cv2.CAP_PROP_FRAME_COUNT)) > 0
    capture.release()
    if not playable:
        raise SystemExit("Annotated output is not a playable MP4")
    print(f"Created {destination}: {summary}")


if __name__ == "__main__":
    main()
