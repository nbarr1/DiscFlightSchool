"""Validation helpers shared by API handlers and tests."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from PIL import Image, UnidentifiedImageError
from PIL.Image import DecompressionBombError

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


def read_and_validate_upload(upload: Any, ext: str, max_bytes: int, dest: Path) -> int:
    """Stream `upload` to `dest`, enforcing the size limit, signature, and
    decodability. Shared by every StorageBackend that accepts uploads, whether
    `dest` is the final on-disk location (FileStorage) or a scratch path later
    uploaded to durable storage. Deletes `dest` and raises ValueError on any
    validation failure. Returns the number of bytes written.
    """
    total = 0
    header = b""
    dest.parent.mkdir(parents=True, exist_ok=True)
    with open(dest, "wb") as output:
        while True:
            chunk = upload.file.read(1024 * 1024)
            if not chunk:
                break
            if not header:
                header = chunk[:16]
            total += len(chunk)
            if total > max_bytes:
                output.close()
                dest.unlink(missing_ok=True)
                raise ValueError("Uploaded image exceeds size limit")
            output.write(chunk)
    if total == 0 or not validate_image_signature(ext, header):
        dest.unlink(missing_ok=True)
        raise ValueError("Uploaded image type does not match an allowed JPEG/PNG signature")
    try:
        validate_decodable_image(dest, ext)
    except ValueError:
        dest.unlink(missing_ok=True)
        raise
    return total


def validate_decodable_image(path: Path, ext: str) -> None:
    """Raise ValueError if the file at `path` isn't a decodable image matching `ext`.

    Shared by every StorageBackend that accepts uploads — decode validation has
    to happen the same way regardless of where the bytes end up being persisted.
    Callers own cleanup of `path` on failure; this function never touches it.
    """
    expected_format = "PNG" if ext == ".png" else "JPEG"
    try:
        with Image.open(path) as image:
            # Read dimensions and format before verify(): verify() closes
            # the underlying file, and touching attributes afterwards is
            # undefined per Pillow's docs.
            width, height = image.size
            image_format = image.format
            image.verify()

        if image_format != expected_format:
            raise ValueError("Uploaded image type does not match its file extension")
        if width <= 0 or height <= 0:
            raise ValueError("Uploaded image dimensions must be positive")
    except DecompressionBombError as exc:
        # A small file can declare enormous dimensions. Pillow refuses to
        # decode it, and DecompressionBombError is NOT an OSError, so
        # without this branch it escapes as an unhandled 500 instead of a
        # 400. Regression covered by test_storage.py.
        raise ValueError("Uploaded image dimensions exceed the decode limit") from exc
    except (UnidentifiedImageError, OSError, SyntaxError) as exc:
        raise ValueError("Uploaded image could not be decoded as JPEG/PNG") from exc


def safe_child(base: Path, filename: str) -> Path:
    base_resolved = base.resolve()
    path = (base_resolved / filename).resolve()
    if base_resolved != path.parent:
        raise ValueError("Unsafe output path")
    return path
