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
    def stats_file(self) -> Path:
        return self.base_dir / "stats.json"

    @property
    def dataset_yaml(self) -> Path:
        return self.dataset_dir / "dataset.yaml"

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
        max_upload_bytes = int(os.environ.get("MAX_UPLOAD_BYTES", str(8 * 1024 * 1024)))
        return cls(
            app_api_key=app_api_key,
            base_dir=base_dir or Path(__file__).resolve().parents[1],
            cors_allow_origins=origins,
            max_upload_bytes=max_upload_bytes,
        )
