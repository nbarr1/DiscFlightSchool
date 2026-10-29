#!/usr/bin/env python3
"""Write the fixture that checks the app's OC-SORT port against Roboflow's.

Runs Roboflow's `trackers` OCSORTTracker, with the disc-flight Workflow's
settings, over synthetic disc flights (noise, missed frames, false positives,
two discs crossing) and records what the Workflow's `tracked_disc` output
would hold each frame. OcSortTrackerTest replays the same input through
the Kotlin port and expects the same detections and tracker ids.

    pip install "trackers==2.4.0" supervision scipy
    python scripts/generate_ocsort_fixture.py \
        disc_golf_android/core/src/test/resources/ocsort_fixture.json

trackers 2.4.0 is the version the Workflow block (`inference` 1.8.3) pins.
"""

from __future__ import annotations

import json
import sys

import numpy as np
import supervision as sv
from trackers import OCSORTTracker

SETTINGS = dict(
    lost_track_buffer=30,
    minimum_consecutive_frames=1,
    minimum_iou_threshold=0.01,
    direction_consistency_weight=0.4,
    high_conf_det_threshold=0.15,
    delta_t=2,
)


def flight(rng: np.random.Generator, frames: int, start, velocity, size) -> list[list[float] | None]:
    boxes = []
    x, y = start
    vx, vy = velocity
    for _ in range(frames):
        x += vx + rng.normal(0, 1.5)
        y += vy + rng.normal(0, 1.5)
        vy += 0.15
        w = size * rng.uniform(0.8, 1.2)
        h = size * rng.uniform(0.5, 1.0)
        boxes.append([x - w / 2, y - h / 2, x + w / 2, y + h / 2])
    return boxes


def scenario(seed: int, fps: float) -> dict:
    rng = np.random.default_rng(seed)
    frames = 90
    discs = [flight(rng, frames, (100, 500), (rng.uniform(6, 14), rng.uniform(-8, -3)), rng.uniform(14, 30))]
    if seed % 2:
        discs.append(flight(rng, frames, (1100, 450), (rng.uniform(-14, -6), rng.uniform(-8, -3)), 20))
    tracker = OCSORTTracker(frame_rate=fps, **SETTINGS)
    # Ids come from a counter shared by every tracker in the process; reset()
    # restarts it, so each scenario numbers its tracks from 0 as a fresh run does.
    tracker.reset()
    out = []
    for frame in range(frames):
        detections = []
        for disc in discs:
            if rng.random() < 0.2:
                continue  # missed frame
            detections.append({"box": disc[frame], "confidence": float(rng.uniform(0.1, 0.95))})
        if rng.random() < 0.15:
            cx, cy = rng.uniform(0, 1280), rng.uniform(0, 720)
            detections.append({"box": [cx - 10, cy - 10, cx + 10, cy + 10], "confidence": float(rng.uniform(0.1, 0.6))})
        rng.shuffle(detections)
        if detections:
            input_ = sv.Detections(
                xyxy=np.array([d["box"] for d in detections], dtype=np.float64),
                confidence=np.array([d["confidence"] for d in detections], dtype=np.float64),
                data={"index": np.arange(len(detections))},
            )
        else:
            input_ = sv.Detections.empty()
            input_.confidence = np.empty(0)
            input_.data["index"] = np.empty(0, dtype=int)
        result = tracker.update(input_)
        # The Workflow block keeps only the detections that got a tracker id.
        tracked = [
            {"index": int(index), "trackerId": int(tid)}
            for index, tid in zip(result.data.get("index", []), result.tracker_id)
            if tid != -1
        ]
        out.append({"detections": detections, "tracked": tracked})
    return {"seed": seed, "fps": fps, "frames": out}


def main() -> int:
    scenarios = [scenario(seed, fps) for seed, fps in [(1, 30.0), (2, 30.0), (3, 60.0), (4, 24.0), (5, 30.0), (6, 15.0)]]
    with open(sys.argv[1], "w") as handle:
        json.dump({"settings": SETTINGS, "scenarios": scenarios}, handle)
    return 0


if __name__ == "__main__":
    sys.exit(main())
