import os

os.environ.setdefault("APP_API_KEY", "test-key")

from main import (  # noqa: E402
    _normalized_image_ext,
    _validate_image_signature,
    _validate_sample_id,
    _validate_yolo_label,
)


def test_sample_id_validation_rejects_path_traversal():
    assert _validate_sample_id("safe_id-123") is None
    assert _validate_sample_id("../unsafe") is not None


def test_yolo_label_validation_allows_single_normalized_disc_row():
    assert _validate_yolo_label("0 0.5 0.5 0.1 0.1") is None
    assert _validate_yolo_label("1 0.5 0.5 0.1 0.1") is not None
    assert _validate_yolo_label("0 1.5 0.5 0.1 0.1") is not None


def test_image_extension_and_signature_validation():
    assert _normalized_image_ext("disc.PNG") == ".png"
    assert _normalized_image_ext("disc.gif") == ".jpg"
    assert _validate_image_signature(".jpg", b"\xff\xd8\xff\x00")
    assert _validate_image_signature(".png", b"\x89PNG\r\n\x1a\n")
    assert not _validate_image_signature(".jpg", b"not-jpeg")
