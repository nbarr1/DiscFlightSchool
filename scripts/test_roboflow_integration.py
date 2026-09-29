#!/usr/bin/env python3
"""Opt-in real Workflow smoke test; never invoked by normal CI.

Environment:
  ROBOFLOW_API_KEY      the server-side Roboflow key (required)
  ROBOFLOW_TEST_VIDEO   a short throw video (required)
  ROBOFLOW_TEST_OUTPUT  where to write the annotated MP4
  ROBOFLOW_TEST_TRACK   where to write the per-frame track as JSON
  ROBOFLOW_TEST_CLIP_MS "start,end" in milliseconds to process only that
                        range, as the app does; either side may be empty
  ROBOFLOW_TEST_SYNTHETIC
                        "1" when the video came from make_synthetic_throw.py,
                        to check each tracked position against the dot's
                        known position
"""

from __future__ import annotations

import json
import os
import statistics
import sys
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))

from training_server.config import Settings  # noqa: E402
from training_server.disc_flight import RoboflowVideoProcessor, UnreadableVideo  # noqa: E402

# Largest median distance, as a fraction of the frame, between the tracked
# box center and the synthetic dot. The dot's radius is about 0.03 of the
# frame height, so a correctly parsed and aligned track sits well inside this.
SYNTHETIC_TOLERANCE = 0.05


def parse_clip(raw: str | None) -> tuple[int, int | None] | None:
    if not raw:
        return None
    start, _, end = raw.partition(",")
    return int(start or 0), int(end) if end.strip() else None


def check_track(track: dict) -> list[dict]:
    """Fail unless the track has the shape the Android app reads."""
    detections = track.get("detections")
    frame_count = track.get("frameCount")
    if not isinstance(detections, list) or not isinstance(frame_count, int) or not track.get("fps"):
        raise SystemExit(f"Track is missing fps, frameCount, or detections: {track}")
    previous = -1
    for detection in detections:
        frame = detection["frame"]
        if not previous < frame < frame_count:
            raise SystemExit(f"Track frames are out of order or out of range: {detection}")
        previous = frame
        for key in ("x", "y", "width", "height"):
            if not 0.0 <= detection[key] <= 1.0:
                raise SystemExit(f"Track {key} is not a fraction of the frame: {detection}")
    return detections


def check_against_synthetic_dot(detections: list[dict], clip: tuple[int, int | None] | None) -> None:
    sys.path.insert(0, str(ROOT / "scripts"))
    from make_synthetic_throw import FPS, HEIGHT, TOTAL_FRAMES, WIDTH, dot_position

    if not detections:
        raise SystemExit("The Workflow tracked no positions on the synthetic clip")
    first_source_frame = round((clip[0] if clip else 0) * FPS / 1000)
    errors = []
    for detection in detections:
        source_frame = first_source_frame + detection["frame"]
        if source_frame >= TOTAL_FRAMES:
            raise SystemExit(f"Track frame {detection['frame']} is past the end of the clip")
        x, y = dot_position(source_frame)
        errors.append(((detection["x"] - x / WIDTH) ** 2 + (detection["y"] - y / HEIGHT) ** 2) ** 0.5)
    median = statistics.median(errors)
    print(f"Synthetic check: median distance {median:.4f} of the frame, worst {max(errors):.4f}")
    if median > SYNTHETIC_TOLERANCE:
        raise SystemExit(
            f"Tracked positions are {median:.3f} of the frame from the dot (limit {SYNTHETIC_TOLERANCE}); "
            "the track's frame numbering or normalization is off"
        )


def main() -> None:
    key = os.environ.get("ROBOFLOW_API_KEY")
    source_name = os.environ.get("ROBOFLOW_TEST_VIDEO")
    if not key or not source_name:
        raise SystemExit("Set ROBOFLOW_API_KEY and ROBOFLOW_TEST_VIDEO to opt in")
    source = Path(source_name)
    if not source.is_file():
        raise SystemExit(f"Test video does not exist: {source}")
    destination = Path(os.environ.get("ROBOFLOW_TEST_OUTPUT", "/tmp/disc-flight-annotated.mp4"))
    track_path = Path(os.environ.get("ROBOFLOW_TEST_TRACK", destination.with_suffix(".track.json")))
    clip = parse_clip(os.environ.get("ROBOFLOW_TEST_CLIP_MS"))
    settings = Settings(app_api_key="integration-only", base_dir=ROOT / "server", roboflow_api_key=key)
    try:
        summary = RoboflowVideoProcessor(settings)(
            source,
            destination,
            threading.Event(),
            lambda done, total, status: print(f"{status}: {done}/{total or '?'}"),
            clip=clip,
        )
    except UnreadableVideo as exc:
        # A share link such as Google Drive's .../view URL downloads an HTML
        # page rather than the video. The processor rejects it before opening
        # a Roboflow session, so no credits are spent.
        raise SystemExit(
            f"{exc} ({source}). If it came from a share link, use a direct download URL."
        ) from None
    import cv2

    capture = cv2.VideoCapture(str(destination))
    playable = capture.isOpened() and int(capture.get(cv2.CAP_PROP_FRAME_COUNT)) > 0
    capture.release()
    if not playable:
        raise SystemExit("Annotated output is not a playable MP4")

    track = summary.pop("track")
    track_path.write_text(json.dumps(track, indent=2))
    detections = check_track(track)
    print(f"Created {destination}: {summary}")
    print(
        f"Track: {len(detections)} of {track['frameCount']} frames have a position "
        f"at {track['fps']:.2f} fps, written to {track_path}"
    )
    for detection in detections[:3] + (["..."] if len(detections) > 6 else []) + detections[-3:]:
        print(f"  {detection}")
    if os.environ.get("ROBOFLOW_TEST_SYNTHETIC") == "1":
        check_against_synthetic_dot(detections, clip)


if __name__ == "__main__":
    main()
