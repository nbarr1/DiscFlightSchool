"""Configuration loading for the training server."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    """Runtime configuration for the FastAPI training server."""

    app_api_key: str
    base_dir: Path
    cors_allow_origins: tuple[str, ...] = ()
    max_upload_bytes: int = 8 * 1024 * 1024
    training_timeout_seconds: int = 7200
    export_timeout_seconds: int = 600
    training_epochs: int = 50
    training_image_size: int = 640
    training_batch_size: int = 16

    @property
    def dataset_dir(self) -> Path:
        return self.base_dir / "dataset"

    @property
    def images_dir(self) -> Path:
        return self.dataset_dir / "images" / "train"

    @property
    def labels_dir(self) -> Path:
        return self.dataset_dir / "labels" / "train"

    @property
    def models_dir(self) -> Path:
        return self.base_dir / "models"

    @property
    def export_dir(self) -> Path:
        return self.base_dir / "exports"

    @property
    def stats_file(self) -> Path:
        return self.base_dir / "stats.json"

    @property
    def dataset_yaml(self) -> Path:
        return self.dataset_dir / "dataset.yaml"

    @staticmethod
    def _positive_int_from_env(name: str, default: int) -> int:
        raw = os.environ.get(name, str(default))
        try:
            value = int(raw)
        except ValueError as exc:
            raise RuntimeError(f"{name} must be a positive integer") from exc
        if value <= 0:
            raise RuntimeError(f"{name} must be a positive integer")
        return value

    @classmethod
    def from_env(cls, *, base_dir: Path | None = None) -> "Settings":
        app_api_key = os.environ.get("APP_API_KEY")
        if not app_api_key:
            raise RuntimeError("APP_API_KEY must be set before starting the training server")

        origins = tuple(
            origin.strip()
            for origin in os.environ.get("CORS_ALLOW_ORIGINS", "").split(",")
            if origin.strip()
        )
        max_upload_bytes = cls._positive_int_from_env("MAX_UPLOAD_BYTES", 8 * 1024 * 1024)
        training_timeout_seconds = cls._positive_int_from_env("TRAINING_TIMEOUT_SECONDS", 7200)
        export_timeout_seconds = cls._positive_int_from_env("MODEL_EXPORT_TIMEOUT_SECONDS", 600)
        training_epochs = cls._positive_int_from_env("TRAINING_EPOCHS", 50)
        training_image_size = cls._positive_int_from_env("TRAINING_IMAGE_SIZE", 640)
        training_batch_size = cls._positive_int_from_env("TRAINING_BATCH_SIZE", 16)
        return cls(
            app_api_key=app_api_key,
            base_dir=base_dir or Path(__file__).resolve().parents[1],
            cors_allow_origins=origins,
            max_upload_bytes=max_upload_bytes,
            training_timeout_seconds=training_timeout_seconds,
            export_timeout_seconds=export_timeout_seconds,
            training_epochs=training_epochs,
            training_image_size=training_image_size,
            training_batch_size=training_batch_size,
        )
