"""
FastAPI entrypoint for Disc Flight School training data collection and model distribution.

Run with: uvicorn main:app --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

from pathlib import Path

from fastapi.responses import JSONResponse

from training_server import Settings, create_app
from training_server.validation import (
    normalized_image_ext,
    sample_id_error,
    validate_image_signature,
    yolo_label_error,
)

settings = Settings.from_env(base_dir=Path(__file__).parent)
app = create_app(settings)

# Backwards-compatible constants and helper names used by existing tests and
# operational snippets. New code should import from training_server.* modules.
APP_API_KEY = settings.app_api_key
MAX_UPLOAD_BYTES = settings.max_upload_bytes
BASE_DIR = settings.base_dir
DATASET_DIR = settings.dataset_dir
IMAGES_DIR = settings.images_dir
LABELS_DIR = settings.labels_dir
MODELS_DIR = settings.models_dir
STATS_FILE = settings.stats_file
DATASET_YAML = settings.dataset_yaml


def _require_api_key(x_app_key: str | None) -> JSONResponse | None:
    """Validate API key header. Returns error response if invalid, None if OK."""
    if x_app_key != APP_API_KEY:
        return JSONResponse({"error": "Invalid or missing API key"}, status_code=403)
    return None


def _validate_sample_id(sample_id: str) -> JSONResponse | None:
    if error := sample_id_error(sample_id):
        return JSONResponse({"error": error}, status_code=400)
    return None


def _validate_yolo_label(label: str) -> JSONResponse | None:
    if error := yolo_label_error(label):
        return JSONResponse({"error": error}, status_code=400)
    return None


def _normalized_image_ext(filename: str | None) -> str:
    return normalized_image_ext(filename)


def _validate_image_signature(ext: str, header: bytes) -> bool:
    return validate_image_signature(ext, header)


def _load_stats() -> dict:
    return app.state.storage.load_stats()


def _save_stats(stats: dict) -> None:
    app.state.storage.save_stats(stats)


def _get_model_info() -> dict | None:
    return app.state.storage.latest_model_info()
