"""Turn a Roboflow COCO export into a truth set grouped by clip."""

from __future__ import annotations

import json
from pathlib import Path

from .clips import SPLITS, leaking_clips, parse_frame_name, split_by_clip

ANNOTATION_FILE = "_annotations.coco.json"


def import_coco_export(
    export_dir: str | Path,
    original_sizes: dict[str, list[int]] | None = None,
    class_name: str = "disc",
) -> dict:
    """Read the train, valid, and test folders of a COCO export.

    The export may be resized, so boxes are normalized by the exported image
    size. `original_sizes` maps an original file name to [width, height], and
    supplies the pixel size the distance tolerance is measured in. Without it
    the exported size is used.
    """
    export_dir = Path(export_dir)
    original_sizes = original_sizes or {}
    clips: dict[str, dict] = {}
    for split in SPLITS:
        path = export_dir / split / ANNOTATION_FILE
        if not path.exists():
            continue
        coco = json.loads(path.read_text(encoding="utf-8"))
        wanted = {c["id"] for c in coco["categories"] if c["name"] == class_name}
        boxes: dict[int, list[list[float]]] = {}
        for annotation in coco["annotations"]:
            if annotation["category_id"] in wanted:
                boxes.setdefault(annotation["image_id"], []).append(annotation["bbox"])
        for image in coco["images"]:
            name = image.get("extra", {}).get("name") or image["file_name"]
            clip_id, frame_number = parse_frame_name(name)
            found = boxes.get(image["id"], [])
            if len(found) > 1:
                raise ValueError(f"{name} has {len(found)} {class_name} boxes; expected at most one")
            size = original_sizes.get(name, [image["width"], image["height"]])
            clip = clips.setdefault(
                clip_id, {"width": size[0], "height": size[1], "frames": []}
            )
            if [clip["width"], clip["height"]] != list(size):
                raise ValueError(f"clip {clip_id!r} has frames of different sizes")
            frame: dict = {"frame": frame_number, "visible": bool(found)}
            if found:
                left, top, width, height = found[0]
                frame.update(
                    x=round((left + width / 2) / image["width"], 5),
                    y=round((top + height / 2) / image["height"], 5),
                    w=round(width / image["width"], 5),
                    h=round(height / image["height"], 5),
                )
            frame["roboflow_split"] = split
            clip["frames"].append(frame)
    for clip in clips.values():
        clip["frames"].sort(key=lambda f: f["frame"])
    assignment = split_by_clip({c: len(body["frames"]) for c, body in clips.items()})
    for clip_id, body in clips.items():
        body["bench_split"] = assignment[clip_id]
    return {"clips": dict(sorted(clips.items()))}


def roboflow_leakage(truth_set: dict) -> dict[str, list[str]]:
    """Clips whose frames Roboflow placed in more than one split."""
    return leaking_clips(
        {
            clip: {f["roboflow_split"] for f in body["frames"] if "roboflow_split" in f}
            for clip, body in truth_set["clips"].items()
        }
    )


def select_split(truth_set: dict, split: str) -> dict:
    """Keep only the clips the clip-level split assigned to `split`."""
    return {
        "clips": {
            clip: body
            for clip, body in truth_set["clips"].items()
            if body.get("bench_split") == split
        }
    }
