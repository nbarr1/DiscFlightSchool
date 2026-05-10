"""Storage protocol boundaries for future durable adapters."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Protocol, TypedDict, runtime_checkable

from fastapi import UploadFile


class DatasetCounts(TypedDict):
    """Counts surfaced by the training stats and training-start workflows."""

    full_images: int
    all_images: int
    labels: int


class ModelInfo(TypedDict):
    """Metadata for the latest model artifact."""

    path: Path
    version: str
    sha256: str


@runtime_checkable
class StorageBackend(Protocol):
    """Storage boundary implemented by filesystem and future durable adapters."""

    def initialize(self) -> None:
        """Prepare any backing directories, buckets, tables, or metadata files."""

    def load_stats(self) -> dict[str, Any]:
        """Load upload statistics for the training stats endpoint."""

    def save_stats(self, stats: dict[str, Any]) -> None:
        """Persist upload statistics."""

    def record_upload(self) -> None:
        """Record one successful training sample upload."""

    def dataset_counts(self) -> DatasetCounts:
        """Return counts used by stats, export, and training-start checks."""

    def store_training_sample(
        self,
        *,
        sample_id: str,
        label: str,
        full_image: UploadFile,
        crop_image: UploadFile,
    ) -> None:
        """Persist a validated training sample and its YOLO label."""

    def latest_model_info(self) -> ModelInfo | None:
        """Return metadata for the latest downloadable model, if one exists."""

    def build_training_export(self) -> Path:
        """Build and return a unique ZIP file containing training data."""
