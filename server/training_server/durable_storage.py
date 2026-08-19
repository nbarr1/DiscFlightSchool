"""StorageBackend implementation backed by PostgreSQL (metadata) and MinIO
(image/model bytes). Selected by `create_app` instead of `FileStorage` only
when `DATABASE_URL` and every `OBJECT_STORAGE_*` variable are configured.
"""

from __future__ import annotations

import hashlib
import shutil
import tempfile
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from fastapi import UploadFile
from minio import Minio
from psycopg.errors import UniqueViolation
from psycopg_pool import ConnectionPool

from .config import Settings, render_dataset_yaml
from .protocols import DatasetCounts, ModelInfo
from .validation import normalized_image_ext, read_and_validate_upload

_SCHEMA_STATEMENTS = (
    """
    CREATE TABLE IF NOT EXISTS training_stats (
        id SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
        total_samples INTEGER NOT NULL DEFAULT 0,
        last_upload TIMESTAMPTZ
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS training_samples (
        sample_id TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        full_image_key TEXT NOT NULL,
        crop_image_key TEXT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS models (
        version TEXT PRIMARY KEY,
        object_key TEXT NOT NULL,
        sha256 TEXT NOT NULL,
        size_bytes BIGINT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS training_runs (
        id UUID PRIMARY KEY,
        status TEXT NOT NULL,
        result TEXT,
        enqueued_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        started_at TIMESTAMPTZ,
        finished_at TIMESTAMPTZ
    )
    """,
    """
    CREATE UNIQUE INDEX IF NOT EXISTS training_runs_one_active
        ON training_runs ((true)) WHERE status IN ('queued', 'running')
    """,
)


def _strip_scheme(endpoint: str) -> str:
    """`Minio()` wants `host:port`, not a URL — `OBJECT_STORAGE_ENDPOINT` is
    always a full URL (e.g. `http://minio:9000`) in .env.example/compose."""
    parsed = urlsplit(endpoint)
    return parsed.netloc or parsed.path


class PostgresMinioStorage:
    """StorageBackend implementation: Postgres for metadata, MinIO for bytes."""

    def __init__(self, settings: Settings, *, pool: ConnectionPool | None = None) -> None:
        self.settings = settings
        assert settings.database_url is not None
        assert settings.object_storage_endpoint is not None
        assert settings.object_storage_bucket is not None
        self.pool = pool or ConnectionPool(
            settings.database_url,
            kwargs={"autocommit": True},
            min_size=1,
            max_size=5,
            open=True,
        )
        self._bucket = settings.object_storage_bucket
        self._minio = Minio(
            _strip_scheme(settings.object_storage_endpoint),
            access_key=settings.object_storage_access_key,
            secret_key=settings.object_storage_secret_key,
            secure=settings.object_storage_secure,
        )

    def initialize(self) -> None:
        with self.pool.connection() as conn:
            for statement in _SCHEMA_STATEMENTS:
                conn.execute(statement)
            conn.execute(
                "INSERT INTO training_stats (id, total_samples, last_upload) "
                "VALUES (1, 0, NULL) ON CONFLICT (id) DO NOTHING"
            )
        if not self._minio.bucket_exists(self._bucket):
            self._minio.make_bucket(self._bucket)

    def load_stats(self) -> dict[str, Any]:
        with self.pool.connection() as conn:
            row = conn.execute(
                "SELECT total_samples, last_upload FROM training_stats WHERE id = 1"
            ).fetchone()
        if row is None:
            return {"total_samples": 0, "last_upload": None}
        total_samples, last_upload = row
        return {
            "total_samples": total_samples,
            "last_upload": last_upload.isoformat() if last_upload else None,
        }

    def save_stats(self, stats: dict[str, Any]) -> None:
        with self.pool.connection() as conn:
            conn.execute(
                "UPDATE training_stats SET total_samples = %s, last_upload = %s WHERE id = 1",
                (stats.get("total_samples", 0), stats.get("last_upload")),
            )

    def record_upload(self) -> None:
        with self.pool.connection() as conn:
            conn.execute(
                "UPDATE training_stats SET total_samples = total_samples + 1, "
                "last_upload = now() WHERE id = 1"
            )

    def dataset_counts(self) -> DatasetCounts:
        with self.pool.connection() as conn:
            row = conn.execute("SELECT count(*) FROM training_samples").fetchone()
        count = row[0] if row else 0
        return {"full_images": count, "all_images": count * 2, "labels": count}

    def store_training_sample(
        self,
        *,
        sample_id: str,
        label: str,
        full_image: UploadFile,
        crop_image: UploadFile,
    ) -> None:
        full_ext = normalized_image_ext(full_image.filename)
        crop_ext = normalized_image_ext(crop_image.filename)
        full_key = f"dataset/images/{sample_id}_full{full_ext}"
        crop_key = f"dataset/images/{sample_id}_crop{crop_ext}"

        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_full = Path(tmp_dir) / f"full{full_ext}"
            tmp_crop = Path(tmp_dir) / f"crop{crop_ext}"
            # Validate before claiming the sample_id, so a bad upload never
            # reserves an id the caller then can't retry.
            read_and_validate_upload(full_image, full_ext, self.settings.max_upload_bytes, tmp_full)
            read_and_validate_upload(crop_image, crop_ext, self.settings.max_upload_bytes, tmp_crop)

            try:
                with self.pool.connection() as conn:
                    conn.execute(
                        "INSERT INTO training_samples "
                        "(sample_id, label, full_image_key, crop_image_key) "
                        "VALUES (%s, %s, %s, %s)",
                        (sample_id, label.strip(), full_key, crop_key),
                    )
            except UniqueViolation as exc:
                raise ValueError("sample_id already exists") from exc

            try:
                self._minio.fput_object(self._bucket, full_key, str(tmp_full))
                self._minio.fput_object(self._bucket, crop_key, str(tmp_crop))
            except Exception:
                with self.pool.connection() as conn:
                    conn.execute(
                        "DELETE FROM training_samples WHERE sample_id = %s", (sample_id,)
                    )
                raise

        self.record_upload()

    def latest_model_info(self) -> ModelInfo | None:
        with self.pool.connection() as conn:
            row = conn.execute(
                "SELECT version, object_key, sha256 FROM models ORDER BY created_at DESC LIMIT 1"
            ).fetchone()
        if row is None:
            return None
        version, object_key, sha256 = row

        local_path = self.settings.models_dir / f"{version}.tflite"
        if not local_path.exists():
            # Common path (worker and API sharing the compose volume) never
            # reaches here — publish_model() already wrote it locally. This
            # only fires for a fresh replica or a non-compose deployment.
            local_path.parent.mkdir(parents=True, exist_ok=True)
            tmp_path = local_path.with_name(f".{local_path.name}.{uuid.uuid4().hex}.tmp")
            self._minio.fget_object(self._bucket, object_key, str(tmp_path))
            tmp_path.replace(local_path)
        return {"path": local_path, "version": version, "sha256": sha256}

    def build_training_export(self) -> Path:
        dataset_dir = self.materialize_dataset()
        export_dir = self.settings.export_dir
        export_dir.mkdir(parents=True, exist_ok=True)
        zip_path = export_dir / f"training_export_{uuid.uuid4().hex}.zip"
        shutil.make_archive(str(zip_path.with_suffix("")), "zip", str(dataset_dir))
        return zip_path

    def materialize_dataset(self) -> Path:
        target = self.settings.base_dir / "materialized_dataset"
        if target.exists():
            shutil.rmtree(target)
        images_dir = target / "images" / "train"
        labels_dir = target / "labels" / "train"
        images_dir.mkdir(parents=True, exist_ok=True)
        labels_dir.mkdir(parents=True, exist_ok=True)

        with self.pool.connection() as conn:
            rows = conn.execute(
                "SELECT sample_id, label, full_image_key, crop_image_key FROM training_samples"
            ).fetchall()

        for sample_id, label, full_key, crop_key in rows:
            full_ext = Path(full_key).suffix
            crop_ext = Path(crop_key).suffix
            self._minio.fget_object(
                self._bucket, full_key, str(images_dir / f"{sample_id}_full{full_ext}")
            )
            self._minio.fget_object(
                self._bucket, crop_key, str(images_dir / f"{sample_id}_crop{crop_ext}")
            )
            (labels_dir / f"{sample_id}_full.txt").write_text(label)

        (target / "dataset.yaml").write_text(render_dataset_yaml(target))
        return target

    def publish_model(self, local_tflite_path: Path, *, version: str) -> ModelInfo:
        object_key = f"models/{version}.tflite"
        sha256 = hashlib.sha256(local_tflite_path.read_bytes()).hexdigest()
        size_bytes = local_tflite_path.stat().st_size

        self._minio.fput_object(self._bucket, object_key, str(local_tflite_path))
        with self.pool.connection() as conn:
            conn.execute(
                "INSERT INTO models (version, object_key, sha256, size_bytes) "
                "VALUES (%s, %s, %s, %s)",
                (version, object_key, sha256, size_bytes),
            )

        self.settings.models_dir.mkdir(parents=True, exist_ok=True)
        dest = self.settings.models_dir / f"{version}.tflite"
        shutil.copy2(local_tflite_path, dest)

        return {"path": dest, "version": version, "sha256": sha256}
