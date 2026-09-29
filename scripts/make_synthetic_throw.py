#!/usr/bin/env python3
"""Write a short synthetic clip for the Roboflow smoke test.

A disc-sized dot on an arc over a green field. This is deliberately not a real
throw: it exists so the smoke test can prove the WebRTC session connects and
the Workflow returns its named outputs without anyone having to host a video.
The Workflow's detector does box the white dot and trace its arc, so the run
exercises detection and tracking as well, but that says nothing about accuracy
on real footage — pass a real clip to check that.
"""

from __future__ import annotations

import sys
from pathlib import Path

import cv2
import numpy as np

WIDTH, HEIGHT, FPS, SECONDS = 640, 360, 30, 3
TOTAL_FRAMES = FPS * SECONDS


def dot_position(index: int) -> tuple[int, int]:
    """The dot's center in pixels on frame `index`, which the Roboflow smoke
    test compares against the per-frame track."""
    progress = index / max(1, TOTAL_FRAMES - 1)
    x = int(60 + progress * (WIDTH - 140))
    y = int(HEIGHT * 0.7 - np.sin(progress * np.pi) * HEIGHT * 0.45)
    return x, y


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: make_synthetic_throw.py <destination.mp4>")
    destination = Path(sys.argv[1])
    writer = cv2.VideoWriter(
        str(destination), cv2.VideoWriter_fourcc(*"mp4v"), FPS, (WIDTH, HEIGHT)
    )
    if not writer.isOpened():
        raise SystemExit(f"Could not open a writer for {destination}")
    try:
        for index in range(TOTAL_FRAMES):
            frame = np.full((HEIGHT, WIDTH, 3), (40, 120, 40), dtype=np.uint8)
            cv2.circle(frame, dot_position(index), 12, (245, 245, 245), -1)
            writer.write(frame)
    finally:
        writer.release()
    print(f"Wrote {destination} ({TOTAL_FRAMES} frames at {FPS} fps)")


if __name__ == "__main__":
    main()
