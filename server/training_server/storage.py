"""Filesystem-backed storage for datasets, stats, exports, and models."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import threading
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any

from fastapi import UploadFile
from PIL import Image, UnidentifiedImageError

from .config import Settings
from .protocols import DatasetCounts, ModelInfo
from .validation import normalized_image_ext, safe_child, validate_image_signature


class FileStorage:
    """Small filesystem adapter preserving the original server storage contract."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._stats_lock = threading.Lock()
        self._model_info_lock = threading.Lock()
        self._model_info_cache: tuple[Path, float, int, str] | None = None

    def initialize(self) -> None:
        self.settings.images_dir.mkdir(parents=True, exist_ok=True)
        self.settings.labels_dir.mkdir(parents=True, exist_ok=True)
        self.settings.models_dir.mkdir(parents=True, exist_ok=True)
        if not self.settings.dataset_yaml.exists():
            self.settings.dataset_yaml.write_text(
                f"path: {self.settings.dataset_dir.resolve()}\n"
                "train: images/train\n"
                "val: images/train\n"
                "\n"
                "names:\n"
                "  0: disc\n"
            )

    def load_stats(self) -> dict[str, Any]:
        if self.settings.stats_file.exists():
            return json.loads(self.settings.stats_file.read_text())
        return {"total_samples": 0, "last_upload": None}

    def save_stats(self, stats: dict[str, Any]) -> None:
        self.settings.stats_file.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = self.settings.stats_file.with_suffix(
            f"{self.settings.stats_file.suffix}.{uuid.uuid4().hex}.tmp"
        )
        tmp_path.write_text(json.dumps(stats, indent=2))
        tmp_path.replace(self.settings.stats_file)

    def record_upload(self) -> None:
        with self._stats_lock:
            stats = self.load_stats()
            stats["total_samples"] = stats.get("total_samples", 0) + 1
            stats["last_upload"] = datetime.now().isoformat()
            self.save_stats(stats)

    def dataset_counts(self) -> DatasetCounts:
        return {
            "full_images": len(list(self.settings.images_dir.glob("*_full.*"))),
            "all_images": len(list(self.settings.images_dir.glob("*.*"))),
            "labels": len(list(self.settings.labels_dir.glob("*.txt"))),
        }

    def copy_upload_image(self, upload: UploadFile, dest: Path, ext: str) -> int:
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
                if total > self.settings.max_upload_bytes:
                    output.close()
                    dest.unlink(missing_ok=True)
                    raise ValueError("Uploaded image exceeds size limit")
                output.write(chunk)
        if total == 0 or not validate_image_signature(ext, header):
            dest.unlink(missing_ok=True)
            raise ValueError("Uploaded image type does not match an allowed JPEG/PNG signature")
        self._validate_decodable_image(dest, ext)
        return total

    def _validate_decodable_image(self, path: Path, ext: str) -> None:
        expected_format = "PNG" if ext == ".png" else "JPEG"
        try:
            with Image.open(path) as image:
                image.verify()
                if image.format != expected_format:
                    raise ValueError("Uploaded image type does not match its file extension")
                if image.width <= 0 or image.height <= 0:
                    raise ValueError("Uploaded image dimensions must be positive")
        except (UnidentifiedImageError, OSError, SyntaxError) as exc:
            path.unlink(missing_ok=True)
            raise ValueError("Uploaded image could not be decoded as JPEG/PNG") from exc
        except ValueError:
            path.unlink(missing_ok=True)
            raise

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
        full_dest = safe_child(self.settings.images_dir, f"{sample_id}_full{full_ext}")
        crop_dest = safe_child(self.settings.images_dir, f"{sample_id}_crop{crop_ext}")
        label_dest = safe_child(self.settings.labels_dir, f"{sample_id}_full.txt")
        final_paths = [full_dest, crop_dest, label_dest]
        lock_path = safe_child(self.settings.labels_dir, f".{sample_id}.lock")
        try:
            lock_fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.close(lock_fd)
        except FileExistsError as exc:
            raise ValueError("sample_id already exists or is being uploaded") from exc

        existing_paths = [path for path in final_paths if path.exists()]
        if existing_paths:
            lock_path.unlink(missing_ok=True)
            raise ValueError("sample_id already exists")

        temp_paths = [
            full_dest.with_name(f".{full_dest.name}.{uuid.uuid4().hex}.tmp"),
            crop_dest.with_name(f".{crop_dest.name}.{uuid.uuid4().hex}.tmp"),
            label_dest.with_name(f".{label_dest.name}.{uuid.uuid4().hex}.tmp"),
        ]

        try:
            self.copy_upload_image(full_image, temp_paths[0], full_ext)
            self.copy_upload_image(crop_image, temp_paths[1], crop_ext)
            temp_paths[2].parent.mkdir(parents=True, exist_ok=True)
            temp_paths[2].write_text(label.strip())

            for temp_path, final_path in zip(temp_paths, final_paths, strict=True):
                temp_path.replace(final_path)
            self.record_upload()
        except Exception:
            for path in (*temp_paths, *final_paths):
                path.unlink(missing_ok=True)
            raise
        finally:
            lock_path.unlink(missing_ok=True)

    def latest_model_info(self) -> ModelInfo | None:
        tflite_files = list(self.settings.models_dir.glob("*.tflite"))
        if not tflite_files:
            return None
        model_path = max(tflite_files, key=lambda path: path.stat().st_mtime)
        stat = model_path.stat()
        with self._model_info_lock:
            cache = self._model_info_cache
            if cache is not None and cache[:3] == (model_path, stat.st_mtime, stat.st_size):
                return {"path": model_path, "version": model_path.stem, "sha256": cache[3]}
        sha256 = hashlib.sha256(model_path.read_bytes()).hexdigest()
        with self._model_info_lock:
            self._model_info_cache = (model_path, stat.st_mtime, stat.st_size, sha256)
        return {"path": model_path, "version": model_path.stem, "sha256": sha256}

    def build_training_export(self) -> Path:
        export_dir = self.settings.export_dir
        export_dir.mkdir(parents=True, exist_ok=True)
        zip_path = export_dir / f"training_export_{uuid.uuid4().hex}.zip"
        shutil.make_archive(str(zip_path.with_suffix("")), "zip", str(self.settings.dataset_dir))
        return zip_path
