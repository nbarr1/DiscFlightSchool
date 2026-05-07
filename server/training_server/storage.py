"""Filesystem-backed storage for datasets, stats, exports, and models."""

from __future__ import annotations

import hashlib
import json
import shutil
from datetime import datetime
from pathlib import Path
from typing import Any

from fastapi import UploadFile

from .config import Settings
from .validation import normalized_image_ext, safe_child, validate_image_signature


class FileStorage:
    """Small filesystem adapter preserving the original server storage contract."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings

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
        self.settings.stats_file.write_text(json.dumps(stats, indent=2))

    def record_upload(self) -> None:
        stats = self.load_stats()
        stats["total_samples"] = stats.get("total_samples", 0) + 1
        stats["last_upload"] = datetime.now().isoformat()
        self.save_stats(stats)

    def dataset_counts(self) -> dict[str, int]:
        return {
            "full_images": len(list(self.settings.images_dir.glob("*_full.*"))),
            "all_images": len(list(self.settings.images_dir.glob("*.*"))),
            "labels": len(list(self.settings.labels_dir.glob("*.txt"))),
        }

    def copy_upload_image(self, upload: UploadFile, dest: Path, ext: str) -> int:
        total = 0
        header = b""
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
        return total

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
        label_dest = safe_child(self.settings.labels_dir, f"{sample_id}.txt")

        self.copy_upload_image(full_image, full_dest, full_ext)
        self.copy_upload_image(crop_image, crop_dest, crop_ext)
        label_dest.write_text(label.strip())
        self.record_upload()

    def latest_model_info(self) -> dict[str, Any] | None:
        tflite_files = list(self.settings.models_dir.glob("*.tflite"))
        if not tflite_files:
            return None
        model_path = max(tflite_files, key=lambda path: path.stat().st_mtime)
        sha256 = hashlib.sha256(model_path.read_bytes()).hexdigest()
        return {"path": model_path, "version": model_path.stem, "sha256": sha256}

    def build_training_export(self) -> Path:
        zip_path = self.settings.base_dir / "training_export.zip"
        shutil.make_archive(str(zip_path.with_suffix("")), "zip", str(self.settings.dataset_dir))
        return zip_path
