"""Training job orchestration."""

from __future__ import annotations

import logging
import threading
from datetime import datetime
from typing import TYPE_CHECKING, Any

from .config import Settings
from .protocols import StorageBackend
from .training_job import TrainingJobError, run_yolo_training_and_export

if TYPE_CHECKING:
    from .queue import TrainingJobQueue, TrainingRunStore

logger = logging.getLogger("disc_flight_school.training_server.training")


class TrainingManager:
    """Starts training either as an in-process thread (default) or, when a
    durable queue is configured, by enqueuing a job the `training-worker`
    container executes. The two modes share the same public interface
    (`start()` / `status`) and the same HTTP response shapes.
    """

    def __init__(
        self,
        settings: Settings,
        storage: StorageBackend,
        *,
        job_queue: "TrainingJobQueue | None" = None,
        run_store: "TrainingRunStore | None" = None,
    ) -> None:
        self._settings = settings
        self._storage = storage
        self._job_queue = job_queue
        self._run_store = run_store
        self._lock = threading.Lock()
        self._status: dict[str, Any] = {"running": False, "last_run": None, "result": None}

    @property
    def status(self) -> dict[str, Any]:
        if self._run_store is not None:
            return self._run_store.latest_status()
        with self._lock:
            return self._status.copy()

    def _set_status(self, **updates: Any) -> None:
        with self._lock:
            self._status.update(updates)

    def start(self) -> tuple[dict[str, Any], int]:
        if self._job_queue is not None and self._run_store is not None:
            return self._start_durable()
        return self._start_in_process()

    def _start_durable(self) -> tuple[dict[str, Any], int]:
        from .queue import RunAlreadyActiveError

        image_count = self._storage.dataset_counts()["full_images"]
        if image_count < 10:
            return {
                "status": "insufficient_data",
                "count": image_count,
                "minimum": 10,
            }, 400

        assert self._run_store is not None
        assert self._job_queue is not None
        try:
            run_id = self._run_store.create_run()
        except RunAlreadyActiveError:
            return {
                "status": "already_running",
                "message": "Training is already in progress",
            }, 409

        self._job_queue.enqueue(run_id)
        return {"status": "started", "message": f"Training started with {image_count} samples"}, 200

    def _start_in_process(self) -> tuple[dict[str, Any], int]:
        with self._lock:
            if self._status["running"]:
                return {
                    "status": "already_running",
                    "message": "Training is already in progress",
                }, 409
            self._status["running"] = True

        # Everything from here until the worker thread is running must clear
        # the flag on failure. Without this, a storage error or a thread that
        # cannot be spawned leaves `running` stuck True and every later call
        # to this endpoint returns 409 until the process restarts.
        try:
            image_count = self._storage.dataset_counts()["full_images"]
            if image_count < 10:
                with self._lock:
                    self._status["running"] = False
                return {
                    "status": "insufficient_data",
                    "count": image_count,
                    "minimum": 10,
                }, 400

            thread = threading.Thread(target=self._run_training, daemon=True)
            thread.start()
        except Exception as exc:
            logger.error("Failed to start training", exc_info=True)
            with self._lock:
                self._status["running"] = False
                self._status["result"] = f"failed to start: {exc}"
            return {"status": "error", "message": "Failed to start training"}, 500

        return {"status": "started", "message": f"Training started with {image_count} samples"}, 200

    def _run_training(self) -> None:
        try:
            self._set_status(result="training")
            dataset_dir = self._storage.materialize_dataset()
            tflite_path = run_yolo_training_and_export(
                self._settings, dataset_dir / "dataset.yaml"
            )
            version = f"disc_detector_v{datetime.now().strftime('%Y%m%d%H%M')}"
            info = self._storage.publish_model(tflite_path, version=version)
            self._set_status(result=f"success: {info['version']}")
        except TrainingJobError as exc:
            self._set_status(result=str(exc))
        except Exception as exc:
            logger.error("Unexpected error during training", exc_info=True)
            self._set_status(result=f"failed: {exc}")
        finally:
            with self._lock:
                self._status["running"] = False
                self._status["last_run"] = datetime.now().isoformat()
