"""Validation helpers — the server's first line of input defence.

Imports from `training_server.validation` directly rather than through the
backwards-compat shims that used to live in main.py, so these test the real
implementation.
"""

import os

os.environ.setdefault("APP_API_KEY", "test-key")

import pytest  # noqa: E402

from training_server.validation import (  # noqa: E402
    normalized_image_ext,
    safe_child,
    sample_id_error,
    validate_image_signature,
    yolo_label_error,
)


# ---- sample_id ----

@pytest.mark.parametrize(
    "sample_id",
    [
        "safe_id-123",
        "a",
        "A" * 80,
        "1234567890",
        "with-hyphens_and_underscores",
    ],
)
def test_sample_id_accepts_safe_values(sample_id):
    assert sample_id_error(sample_id) is None


@pytest.mark.parametrize(
    "sample_id",
    [
        "../unsafe",
        "..",
        "a/b",
        "a\\b",
        "",
        "A" * 81,          # over the 80-char cap
        "has space",
        "dot.separated",   # would change the stored file extension
        "semi;colon",
        "null\x00byte",
        "unicode-é",
        "\n",
        "-'; DROP TABLE --",
    ],
)
def test_sample_id_rejects_unsafe_values(sample_id):
    assert sample_id_error(sample_id) is not None


# ---- YOLO label ----

@pytest.mark.parametrize(
    "label",
    [
        "0 0.5 0.5 0.1 0.1",
        "0 0 0 0 0",
        "0 1 1 1 1",
        "0 1.0 1.0 1.0 1.0",
        "0 0.123456 0.5 0.1 0.1",
        "  0 0.5 0.5 0.1 0.1  ",  # surrounding whitespace is trimmed
    ],
)
def test_yolo_label_accepts_single_normalized_disc_row(label):
    assert yolo_label_error(label) is None


@pytest.mark.parametrize(
    "label",
    [
        "1 0.5 0.5 0.1 0.1",        # non-zero class
        "0 1.5 0.5 0.1 0.1",        # out of [0,1]
        "0 -0.5 0.5 0.1 0.1",       # negative
        "0 0.5 0.5 0.1",            # too few fields
        "0 0.5 0.5 0.1 0.1 0.1",    # too many fields
        "0 0.5 0.5 0.1 0.1\n0 0.2 0.2 0.1 0.1",  # multiple rows
        "",
        "   ",
        "not a label",
        "0 a b c d",
        "0 1e-1 0.5 0.1 0.1",       # scientific notation
    ],
)
def test_yolo_label_rejects_everything_else(label):
    assert yolo_label_error(label) is not None


# ---- image extension / signature ----

@pytest.mark.parametrize(
    "filename,expected",
    [
        ("disc.PNG", ".png"),
        ("disc.png", ".png"),
        ("disc.JPG", ".jpg"),
        ("disc.jpeg", ".jpeg"),
        ("disc.gif", ".jpg"),      # unknown types fall back to .jpg
        ("disc", ".jpg"),
        (None, ".jpg"),
        ("archive.tar.gz", ".jpg"),
        ("disc.png.exe", ".jpg"),  # only the final suffix counts
    ],
)
def test_normalized_image_ext(filename, expected):
    assert normalized_image_ext(filename) == expected


def test_image_signature_validation():
    assert validate_image_signature(".jpg", b"\xff\xd8\xff\x00")
    assert validate_image_signature(".jpeg", b"\xff\xd8\xff\x00")
    assert validate_image_signature(".png", b"\x89PNG\r\n\x1a\n")
    assert not validate_image_signature(".jpg", b"not-jpeg")
    assert not validate_image_signature(".png", b"\xff\xd8\xff\x00")  # jpeg as png
    assert not validate_image_signature(".jpg", b"")
    assert not validate_image_signature(".jpg", b"\xff\xd8")          # truncated


# ---- safe_child (path traversal) ----

def test_safe_child_returns_path_inside_base(tmp_path):
    result = safe_child(tmp_path, "sample_full.jpg")
    assert result.parent == tmp_path.resolve()
    assert result.name == "sample_full.jpg"


@pytest.mark.parametrize(
    "filename",
    [
        "../escape.jpg",
        "../../escape.jpg",
        "nested/child.jpg",
        "/absolute/path.jpg",
    ],
)
def test_safe_child_rejects_escapes(tmp_path, filename):
    with pytest.raises(ValueError):
        safe_child(tmp_path, filename)
