"""Score a tracker's output against labeled frames.

Only labeled frames are scored. A prediction on a visible frame is correct
when it lies within `tolerance` of the label, measured in pixels as a
fraction of the frame diagonal.
"""

from __future__ import annotations

import math
import statistics
from dataclasses import asdict, dataclass

from .formats import PredictedClip, Predictions, TruthClip

DEFAULT_TOLERANCE = 0.02
FALSE_TRAIL_MIN_POINTS = 3
FALSE_TRAIL_PRECISION = 0.5


@dataclass(frozen=True)
class Targets:
    """Pass marks for a method. These are proposals until a baseline exists."""

    located: float = 0.85
    false_trail_clips: float = 0.05
    seconds_per_clip: float = 30.0


@dataclass(frozen=True)
class ClipScore:
    clip: str
    visible_frames: int
    empty_frames: int
    located: int
    covered: int
    wrong: int
    false_points: int
    median_error: float | None
    seconds: float | None

    @property
    def scored_points(self) -> int:
        """Predictions that fell on a labeled frame."""
        return self.covered + self.false_points

    @property
    def precision(self) -> float | None:
        return self.located / self.scored_points if self.scored_points else None

    @property
    def is_false_trail(self) -> bool:
        """True when most of what the tracker drew was not the disc."""
        precision = self.precision
        return (
            self.scored_points >= FALSE_TRAIL_MIN_POINTS
            and precision is not None
            and precision < FALSE_TRAIL_PRECISION
        )


@dataclass(frozen=True)
class Summary:
    method: str
    clips: int
    visible_frames: int
    located_rate: float | None
    coverage_rate: float | None
    precision: float | None
    false_trail_clip_rate: float | None
    worst_clip_located_rate: float | None
    median_error: float | None
    mean_seconds: float | None
    max_seconds: float | None

    def to_dict(self) -> dict:
        return asdict(self)


def score_clip(
    truth: TruthClip,
    predicted: PredictedClip | None,
    tolerance: float = DEFAULT_TOLERANCE,
) -> ClipScore:
    points = {p.frame: p for p in predicted.points} if predicted else {}
    diagonal = math.hypot(truth.width, truth.height)
    located = covered = false_points = visible = empty = 0
    errors: list[float] = []
    for frame in truth.frames:
        point = points.get(frame.frame)
        if not frame.visible:
            empty += 1
            if point is not None:
                false_points += 1
            continue
        visible += 1
        if point is None:
            continue
        covered += 1
        error = (
            math.hypot(
                (point.x - frame.x) * truth.width, (point.y - frame.y) * truth.height
            )
            / diagonal
        )
        if error <= tolerance:
            located += 1
            errors.append(error)
    return ClipScore(
        clip=truth.clip,
        visible_frames=visible,
        empty_frames=empty,
        located=located,
        covered=covered,
        wrong=covered - located,
        false_points=false_points,
        median_error=statistics.median(errors) if errors else None,
        seconds=predicted.seconds if predicted else None,
    )


def _rate(numerator: int, denominator: int) -> float | None:
    return numerator / denominator if denominator else None


def summarize(method: str, scores: list[ClipScore]) -> Summary:
    visible = sum(s.visible_frames for s in scores)
    located = sum(s.located for s in scores)
    medians = [s.median_error for s in scores if s.median_error is not None]
    seconds = [s.seconds for s in scores if s.seconds is not None]
    per_clip = [s.located / s.visible_frames for s in scores if s.visible_frames]
    return Summary(
        method=method,
        clips=len(scores),
        visible_frames=visible,
        located_rate=_rate(located, visible),
        coverage_rate=_rate(sum(s.covered for s in scores), visible),
        precision=_rate(located, sum(s.scored_points for s in scores)),
        false_trail_clip_rate=_rate(sum(s.is_false_trail for s in scores), len(scores)),
        worst_clip_located_rate=min(per_clip) if per_clip else None,
        median_error=statistics.median(medians) if medians else None,
        mean_seconds=statistics.fmean(seconds) if seconds else None,
        max_seconds=max(seconds) if seconds else None,
    )


def score(
    truth: dict[str, TruthClip],
    predictions: Predictions,
    tolerance: float = DEFAULT_TOLERANCE,
) -> tuple[Summary, list[ClipScore]]:
    """Score every truth clip. A clip the method skipped scores as all misses."""
    unknown = sorted(set(predictions.clips) - set(truth))
    if unknown:
        raise ValueError(f"predictions name clips with no ground truth: {unknown}")
    scores = [
        score_clip(clip, predictions.clips.get(name), tolerance)
        for name, clip in sorted(truth.items())
    ]
    return summarize(predictions.method, scores), scores


def failures(summary: Summary, targets: Targets = Targets()) -> list[str]:
    """Return one line per missed target. An unmeasured value counts as a miss."""
    missed: list[str] = []
    if summary.located_rate is None or summary.located_rate < targets.located:
        missed.append(f"located rate {_show(summary.located_rate)} is under {targets.located:.0%}")
    if (
        summary.false_trail_clip_rate is None
        or summary.false_trail_clip_rate > targets.false_trail_clips
    ):
        missed.append(
            f"false-trail clips {_show(summary.false_trail_clip_rate)} is over "
            f"{targets.false_trail_clips:.0%}"
        )
    if summary.max_seconds is None:
        missed.append("processing time was not reported")
    elif summary.max_seconds > targets.seconds_per_clip:
        missed.append(
            f"slowest clip took {summary.max_seconds:.1f} s, over "
            f"{targets.seconds_per_clip:.0f} s"
        )
    return missed


def _show(rate: float | None) -> str:
    return "not measured" if rate is None else f"{rate:.1%}"
