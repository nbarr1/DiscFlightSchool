"""Find which video frame each labeled image came from.

The labeled images were extracted from the videos before this tool existed,
and their file names count extracted frames, not video frames. This module
recovers the video frame by comparing each labeled image with every frame of
its clip at a small size. It needs `ffmpeg` on the path and `numpy`; the rest
of the package needs neither.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

from .clips import SPLITS, parse_frame_name
from .roboflow import ANNOTATION_FILE

THUMB = 64
# Mean squared difference of 8-bit gray thumbnails. A labeled image and its
# own video frame differ only by JPEG and resize noise, which measures under 1.
MAX_MATCH_ERROR = 4.0


def _thumbnails(source: Path, every_frame: bool):
    import numpy as np

    command = ["ffmpeg", "-v", "error", "-i", str(source)]
    if every_frame:
        command += ["-fps_mode", "passthrough"]
    command += ["-vf", f"scale={THUMB}:{THUMB},format=gray", "-f", "rawvideo", "-"]
    data = subprocess.run(command, capture_output=True, check=True).stdout
    return np.frombuffer(data, np.uint8).reshape(-1, THUMB, THUMB).astype(np.float32)


def _video_info(video: Path) -> dict:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_packets",
         "-show_entries", "stream=avg_frame_rate,nb_read_packets", "-of", "json", str(video)],
        capture_output=True, check=True, text=True,
    ).stdout
    stream = json.loads(out)["streams"][0]
    numerator, denominator = stream["avg_frame_rate"].split("/")
    return {
        "file": video.name,
        "frames": int(stream["nb_read_packets"]),
        "fps": round(int(numerator) / int(denominator), 3),
    }


def match_export_to_videos(export_dir: str | Path, video_dir: str | Path) -> dict:
    """Return {clip: {"video": info, "frames": {label frame: video frame}}}.

    Video frames are counted from 0 in decode order. Clips with no video file
    in `video_dir` are left out.
    """
    export_dir, video_dir = Path(export_dir), Path(video_dir)
    images: dict[str, dict[int, Path]] = {}
    for split in SPLITS:
        path = export_dir / split / ANNOTATION_FILE
        if not path.exists():
            continue
        for image in json.loads(path.read_text(encoding="utf-8"))["images"]:
            name = image.get("extra", {}).get("name") or image["file_name"]
            clip, number = parse_frame_name(name)
            images.setdefault(clip, {})[number] = export_dir / split / image["file_name"]
    result: dict[str, dict] = {}
    for clip, by_number in sorted(images.items()):
        video = video_dir / f"{clip}.mp4"
        if not video.exists():
            continue
        frames = _thumbnails(video, every_frame=True)
        matched: dict[int, int] = {}
        for number, image_path in sorted(by_number.items()):
            errors = ((frames - _thumbnails(image_path, every_frame=False)[0]) ** 2).mean(axis=(1, 2))
            best = int(errors.argmin())
            if errors[best] > MAX_MATCH_ERROR:
                raise ValueError(
                    f"{image_path.name} matches no frame of {video.name} "
                    f"(best error {errors[best]:.1f})"
                )
            matched[number] = best
        result[clip] = {"video": _video_info(video), "frames": matched}
    return result


def apply_video_frames(truth_set: dict, matches: dict) -> dict:
    """Renumber matched clips by video frame, keeping the old number.

    A matched clip gets `"frame_numbering": "video"`, each frame's `frame`
    becomes the 0-based video frame, and the file-name number moves to
    `label_frame`. Unmatched clips get `"frame_numbering": "label"`.
    """
    for clip, body in truth_set["clips"].items():
        match = matches.get(clip)
        if body.get("frame_numbering") == "video":
            continue
        if match is None:
            body["frame_numbering"] = "label"
            continue
        mapping = {int(k): v for k, v in match["frames"].items()}
        for frame in body["frames"]:
            frame["label_frame"] = frame["frame"]
            frame["frame"] = mapping[frame["label_frame"]]
        body["frames"].sort(key=lambda f: f["frame"])
        body["frame_numbering"] = "video"
        body["video"] = match["video"]
    return truth_set
