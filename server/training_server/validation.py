"""Validation helpers shared by API handlers and tests."""

from __future__ import annotations

import re
from pathlib import Path

SAFE_SAMPLE_ID = re.compile(r"^[A-Za-z0-9_-]{1,80}$")
YOLO_LABEL = re.compile(
    r"^0\s+"
    r"(?:0(?:\.\d+)?|1(?:\.0+)?)\s+"
    r"(?:0(?:\.\d+)?|1(?:\.0+)?)\s+"
    r"(?:0(?:\.\d+)?|1(?:\.0+)?)\s+"
    r"(?:0(?:\.\d+)?|1(?:\.0+)?)$"
)
IMAGE_SIGNATURES: dict[str, tuple[bytes, ...]] = {
    ".jpg": (b"\xff\xd8\xff",),
    ".jpeg": (b"\xff\xd8\xff",),
    ".png": (b"\x89PNG\r\n\x1a\n",),
}


def sample_id_error(sample_id: str) -> str | None:
    if SAFE_SAMPLE_ID.fullmatch(sample_id):
        return None
    return "sample_id must contain only letters, numbers, underscores, and hyphens"


def yolo_label_error(label: str) -> str | None:
    lines = [line.strip() for line in label.strip().splitlines() if line.strip()]
    if len(lines) == 1 and YOLO_LABEL.fullmatch(lines[0]):
        return None
    return "label must be a single YOLO class-0 row with normalized values"


def normalized_image_ext(filename: str | None) -> str:
    ext = Path(filename or "image.jpg").suffix.lower()
    if ext in IMAGE_SIGNATURES:
        return ext
    return ".jpg"


def validate_image_signature(ext: str, header: bytes) -> bool:
    return any(header.startswith(signature) for signature in IMAGE_SIGNATURES[ext])


def safe_child(base: Path, filename: str) -> Path:
    base_resolved = base.resolve()
    path = (base_resolved / filename).resolve()
    if base_resolved != path.parent:
        raise ValueError("Unsafe output path")
    return path
