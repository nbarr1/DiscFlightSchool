"""File formats for ground truth and for tracker output.

Both are JSON. Positions are the disc center, normalized to 0-1 of the frame
width and height, with the origin at the top left.

Truth set::

    {"clips": {"<clip id>": {
        "width": 1080, "height": 1920,
        "frames": [
            {"frame": 12, "visible": true, "x": 0.41, "y": 0.52, "w": 0.02, "h": 0.01},
            {"frame": 13, "visible": false}
        ]}}}

A frame that isn't listed is unlabeled and is never scored. A frame with
`"visible": false` was checked and holds no disc.

Predictions::

    {"method": "<name>", "clips": {"<clip id>": {
        "seconds": 4.2,
        "frames": [{"frame": 12, "x": 0.40, "y": 0.52, "confidence": 0.8}]}}}

A frame that isn't listed means the tracker drew nothing there. `seconds` is
the processing time for the clip and is optional.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path


@dataclass(frozen=True)
class TruthFrame:
    frame: int
    visible: bool
    x: float | None = None
    y: float | None = None


@dataclass(frozen=True)
class TruthClip:
    clip: str
    width: int
    height: int
    frames: tuple[TruthFrame, ...]


@dataclass(frozen=True)
class PredictedPoint:
    frame: int
    x: float
    y: float


@dataclass(frozen=True)
class PredictedClip:
    clip: str
    points: tuple[PredictedPoint, ...] = ()
    seconds: float | None = None


@dataclass(frozen=True)
class Predictions:
    method: str
    clips: dict[str, PredictedClip] = field(default_factory=dict)


def _unique_frames(clip: str, frames: list[dict]) -> None:
    seen: set[int] = set()
    for entry in frames:
        number = entry["frame"]
        if number in seen:
            raise ValueError(f"clip {clip!r} lists frame {number} twice")
        seen.add(number)


def parse_truth(data: dict) -> dict[str, TruthClip]:
    clips: dict[str, TruthClip] = {}
    for clip, body in data["clips"].items():
        _unique_frames(clip, body["frames"])
        frames = []
        for entry in body["frames"]:
            visible = bool(entry["visible"])
            if visible and ("x" not in entry or "y" not in entry):
                raise ValueError(
                    f"clip {clip!r} frame {entry['frame']} is visible but has no x and y"
                )
            frames.append(
                TruthFrame(
                    frame=int(entry["frame"]),
                    visible=visible,
                    x=float(entry["x"]) if visible else None,
                    y=float(entry["y"]) if visible else None,
                )
            )
        if body["width"] <= 0 or body["height"] <= 0:
            raise ValueError(f"clip {clip!r} needs a positive width and height")
        clips[clip] = TruthClip(
            clip=clip,
            width=int(body["width"]),
            height=int(body["height"]),
            frames=tuple(sorted(frames, key=lambda f: f.frame)),
        )
    return clips


def parse_predictions(data: dict) -> Predictions:
    clips: dict[str, PredictedClip] = {}
    for clip, body in data["clips"].items():
        _unique_frames(clip, body["frames"])
        seconds = body.get("seconds")
        clips[clip] = PredictedClip(
            clip=clip,
            points=tuple(
                PredictedPoint(int(p["frame"]), float(p["x"]), float(p["y"]))
                for p in body["frames"]
            ),
            seconds=float(seconds) if seconds is not None else None,
        )
    return Predictions(method=str(data.get("method", "unnamed")), clips=clips)


def load_truth(path: str | Path) -> dict[str, TruthClip]:
    return parse_truth(json.loads(Path(path).read_text(encoding="utf-8")))


def load_predictions(path: str | Path) -> Predictions:
    return parse_predictions(json.loads(Path(path).read_text(encoding="utf-8")))
