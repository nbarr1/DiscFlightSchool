"""Group labeled frames by source clip and split them by clip.

Frames extracted from one throw look alike, so a split that puts frames of
one clip in both the training and the test set overstates accuracy. Every
function here keeps a clip whole.
"""

from __future__ import annotations

import re

_FRAME_NAME = re.compile(r"^(?P<clip>.+)_frame_(?P<frame>\d+)\.[A-Za-z0-9]+$")

SPLITS = ("train", "valid", "test")


def parse_frame_name(name: str) -> tuple[str, int]:
    """Return (clip id, frame number) for a name like `clip_frame_012.jpg`."""
    match = _FRAME_NAME.match(name)
    if not match:
        raise ValueError(f"not a frame file name: {name!r}")
    return match.group("clip"), int(match.group("frame"))


def split_by_clip(
    frame_counts: dict[str, int], valid: float = 0.15, test: float = 0.15
) -> dict[str, str]:
    """Assign each clip to train, valid, or test, keeping clips whole.

    Clips are taken largest first, and each one goes to the split that is
    furthest below its target share of frames. The result depends only on the
    counts and names, so the same labels always give the same split.
    """
    if not 0 <= valid < 1 or not 0 <= test < 1 or valid + test >= 1:
        raise ValueError("valid and test must be fractions that sum to less than 1")
    total = sum(frame_counts.values())
    targets = {"train": 1 - valid - test, "valid": valid, "test": test}
    filled = {split: 0 for split in SPLITS}
    assignment: dict[str, str] = {}
    for clip in sorted(frame_counts, key=lambda c: (-frame_counts[c], c)):
        # Deficit is measured in frames; ties go to train, then valid, then test.
        split = max(SPLITS, key=lambda s: targets[s] * total - filled[s])
        assignment[clip] = split
        filled[split] += frame_counts[clip]
    return assignment


def leaking_clips(clip_splits: dict[str, set[str]]) -> dict[str, list[str]]:
    """Return the clips whose frames sit in more than one split."""
    return {
        clip: sorted(splits)
        for clip, splits in sorted(clip_splits.items())
        if len(splits) > 1
    }
