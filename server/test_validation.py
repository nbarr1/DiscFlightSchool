import os

os.environ.setdefault("APP_API_KEY", "test-key")

from main import _validate_sample_id, _validate_yolo_label  # noqa: E402


def test_sample_id_validation_rejects_path_traversal():
    assert _validate_sample_id("safe_id-123") is None
    assert _validate_sample_id("../unsafe") is not None


def test_yolo_label_validation_allows_single_normalized_disc_row():
    assert _validate_yolo_label("0 0.5 0.5 0.1 0.1") is None
    assert _validate_yolo_label("1 0.5 0.5 0.1 0.1") is not None
    assert _validate_yolo_label("0 1.5 0.5 0.1 0.1") is not None
