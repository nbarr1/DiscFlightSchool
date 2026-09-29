"""The YOLO train+export subprocess sequence, shared by every execution path.

Both the in-process thread (`TrainingManager._run_training`, used when no
durable queue is configured) and the Redis-queue worker call this same
function, so the subprocess/timeout/export sequence exists exactly once.
"""

from __future__ import annotations

import subprocess
import time
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

    export_started = time.time()
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

    # A little slack for filesystems with coarse modification times; training
    # takes minutes, so nothing from a previous run is that recent.
    tflite = find_exported_tflite(best_pt, not_before=export_started - 2)
    if tflite is None:
        raise TrainingJobError("failed: no TFLite model produced")
    return tflite


def find_exported_tflite(best_pt: Path, *, not_before: float = 0.0) -> Path | None:
    """The .tflite the export just wrote for `best_pt`, or None.

    Where it lands depends on the ultralytics version `requirements.txt`
    allows: 8.4.83 and later export LiteRT to `best.tflite` beside the
    weights, while earlier 8.x releases write `best_float32.tflite` (and
    `best_float16.tflite`) into a `best_saved_model/` folder. The runs folder
    is reused between trainings, so files older than `not_before` are ignored
    rather than republishing a previous run's model.
    """
    weights = best_pt.parent
    preferred = (
        weights / f"{best_pt.stem}.tflite",
        weights / f"{best_pt.stem}_saved_model" / f"{best_pt.stem}_float32.tflite",
    )
    others = sorted(weights.rglob("*.tflite"))
    for candidate in (*preferred, *others):
        try:
            if candidate.is_file() and candidate.stat().st_mtime >= not_before:
                return candidate
        except OSError:
            continue
    return None
