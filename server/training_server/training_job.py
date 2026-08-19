"""The YOLO train+export subprocess sequence, shared by every execution path.

Both the in-process thread (`TrainingManager._run_training`, used when no
durable queue is configured) and the Redis-queue worker call this same
function, so the subprocess/timeout/export sequence exists exactly once.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

from .config import Settings


class TrainingJobError(Exception):
    """Raised when the YOLO train or export subprocess fails or times out."""


def run_yolo_training_and_export(settings: Settings, dataset_yaml: Path) -> Path:
    """Run `yolo detect train` then `yolo export ... format=tflite`.

    Returns the local path to the produced .tflite file. Raises
    TrainingJobError with a message suitable for a status/result string.
    """
    result = subprocess.run(
        [
            "yolo",
            "detect",
            "train",
            f"data={dataset_yaml.resolve()}",
            "model=yolo11n.pt",
            f"epochs={settings.training_epochs}",
            f"imgsz={settings.training_image_size}",
            f"batch={settings.training_batch_size}",
            f"project={settings.base_dir / 'runs'}",
            "name=disc_detector",
            "exist_ok=True",
        ],
        capture_output=True,
        text=True,
        timeout=settings.training_timeout_seconds,
    )
    if result.returncode != 0:
        raise TrainingJobError(f"failed: {result.stderr[-500:]}")

    best_pt = settings.base_dir / "runs" / "disc_detector" / "weights" / "best.pt"
    if not best_pt.exists():
        raise TrainingJobError("failed: no trained weights produced")

    export_result = subprocess.run(
        [
            "yolo",
            "export",
            f"model={best_pt}",
            "format=tflite",
            f"imgsz={settings.training_image_size}",
        ],
        capture_output=True,
        text=True,
        timeout=settings.export_timeout_seconds,
    )
    if export_result.returncode != 0:
        raise TrainingJobError(f"failed export: {export_result.stderr[-500:]}")

    for tflite in best_pt.parent.glob("*.tflite"):
        return tflite

    raise TrainingJobError("failed: no TFLite model produced")
