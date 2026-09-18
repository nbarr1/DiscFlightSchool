#!/usr/bin/env python3
"""Write a short synthetic clip for the Roboflow smoke test.

A disc-sized dot on an arc over a green field. This is deliberately not a real
throw: it exists so the smoke test can prove the WebRTC session connects and
the Workflow returns its named outputs without anyone having to host a video.
Expect no detections from it — pass a real clip to check those.
"""

from __future__ import annotations

import sys
from pathlib import Path

import cv2
import numpy as np

WIDTH, HEIGHT, FPS, SECONDS = 640, 360, 30, 3


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: make_synthetic_throw.py <destination.mp4>")
    destination = Path(sys.argv[1])
    writer = cv2.VideoWriter(
        str(destination), cv2.VideoWriter_fourcc(*"mp4v"), FPS, (WIDTH, HEIGHT)
    )
    if not writer.isOpened():
        raise SystemExit(f"Could not open a writer for {destination}")
    total = FPS * SECONDS
    try:
        for index in range(total):
            frame = np.full((HEIGHT, WIDTH, 3), (40, 120, 40), dtype=np.uint8)
            progress = index / max(1, total - 1)
            x = int(60 + progress * (WIDTH - 140))
            y = int(HEIGHT * 0.7 - np.sin(progress * np.pi) * HEIGHT * 0.45)
            cv2.circle(frame, (x, y), 12, (245, 245, 245), -1)
            writer.write(frame)
    finally:
        writer.release()
    print(f"Wrote {destination} ({total} frames at {FPS} fps)")


if __name__ == "__main__":
    main()
