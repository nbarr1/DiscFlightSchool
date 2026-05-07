"""Training job orchestration."""

from __future__ import annotations

import shutil
import subprocess
import threading
from datetime import datetime
from typing import Any

from .config import Settings
from .storage import FileStorage


class TrainingManager:
    """Thread-backed training manager preserving the original endpoint behavior."""

    def __init__(self, settings: Settings, storage: FileStorage) -> None:
        self._settings = settings
        self._storage = storage
        self._lock = threading.Lock()
        self._status: dict[str, Any] = {"running": False, "last_run": None, "result": None}

    @property
    def status(self) -> dict[str, Any]:
        return self._status

    def start(self) -> tuple[dict[str, Any], int]:
        with self._lock:
            if self._status["running"]:
                return {
                    "status": "already_running",
                    "message": "Training is already in progress",
                }, 409
            self._status["running"] = True

        image_count = self._storage.dataset_counts()["full_images"]
        if image_count < 10:
            with self._lock:
                self._status["running"] = False
            return {"status": "insufficient_data", "count": image_count, "minimum": 10}, 400

        thread = threading.Thread(target=self._run_training, daemon=True)
        thread.start()
        return {"status": "started", "message": f"Training started with {image_count} samples"}, 200

    def _run_training(self) -> None:
        try:
            self._status["result"] = "training"
            result = subprocess.run(
                [
                    "yolo",
                    "detect",
                    "train",
                    f"data={self._settings.dataset_yaml.resolve()}",
                    "model=yolov8n.pt",
                    "epochs=50",
                    "imgsz=640",
                    "batch=16",
                    f"project={self._settings.base_dir / 'runs'}",
                    "name=disc_detector",
                    "exist_ok=True",
                ],
                capture_output=True,
                text=True,
                timeout=7200,
            )

            if result.returncode != 0:
                self._status["result"] = f"failed: {result.stderr[-500:]}"
                return

            best_pt = self._settings.base_dir / "runs" / "disc_detector" / "weights" / "best.pt"
            if best_pt.exists():
                export_result = subprocess.run(
                    ["yolo", "export", f"model={best_pt}", "format=tflite", "imgsz=640"],
                    capture_output=True,
                    text=True,
                    timeout=600,
                )
                if export_result.returncode != 0:
                    self._status["result"] = f"failed export: {export_result.stderr[-500:]}"
                    return

                for tflite in best_pt.parent.glob("*.tflite"):
                    version = f"disc_detector_v{datetime.now().strftime('%Y%m%d%H%M')}"
                    dest = self._settings.models_dir / f"{version}.tflite"
                    shutil.copy2(tflite, dest)
                    self._status["result"] = f"success: {version}"
                    return

            self._status["result"] = "failed: no TFLite model produced"
        except subprocess.TimeoutExpired:
            self._status["result"] = "failed: training timed out"
        except Exception as exc:
            self._status["result"] = f"failed: {exc}"
        finally:
            with self._lock:
                self._status["running"] = False
                self._status["last_run"] = datetime.now().isoformat()
