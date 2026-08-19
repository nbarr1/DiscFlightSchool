"""Worker entrypoint for the durable runtime stack.

When Postgres/Redis/MinIO are configured, this is a real Redis-queue
consumer: it pops a training job, runs the same `yolo detect train` /
`yolo export` sequence the in-process path uses, publishes the resulting
model through the storage layer, and records the run's outcome in Postgres
so `GET /api/training/status` can read it from the API process.

When they are not configured, a worker container makes no sense (there's no
queue to consume), so this keeps the original placeholder behavior — log
config booleans and sleep — so `docker compose up` with the durable vars
unset still behaves predictably instead of crashing.
"""

from __future__ import annotations

import json
import logging
import os
import time
from datetime import datetime
from pathlib import Path

from .config import Settings
from .training_job import TrainingJobError, run_yolo_training_and_export

logger = logging.getLogger("disc_flight_school.training_server.worker")


def _run_durable_worker(settings: Settings, poll_seconds: int) -> None:
    from psycopg_pool import ConnectionPool
    from redis import Redis

    from .durable_storage import PostgresMinioStorage
    from .queue import TrainingJobQueue, TrainingRunStore

    assert settings.database_url is not None
    assert settings.redis_url is not None

    pool = ConnectionPool(
        settings.database_url, kwargs={"autocommit": True}, min_size=1, max_size=5, open=True
    )
    storage = PostgresMinioStorage(settings, pool=pool)
    storage.initialize()
    job_queue = TrainingJobQueue(Redis.from_url(settings.redis_url))
    run_store = TrainingRunStore(pool)

    logger.info(json.dumps({"event": "worker.ready", "mode": "durable-queue"}))

    while True:
        job_id = job_queue.pop(poll_seconds)
        if job_id is None:
            continue

        logger.info(json.dumps({"event": "worker.job.claimed", "job_id": job_id}))
        run_store.mark_running(job_id)
        try:
            dataset_dir = storage.materialize_dataset()
            tflite_path = run_yolo_training_and_export(settings, dataset_dir / "dataset.yaml")
            version = f"disc_detector_v{datetime.now().strftime('%Y%m%d%H%M')}"
            info = storage.publish_model(tflite_path, version=version)
            run_store.mark_finished(job_id, status="success", result=f"success: {info['version']}")
        except TrainingJobError as exc:
            run_store.mark_finished(job_id, status="failed", result=str(exc))
        except Exception as exc:
            logger.error("Unexpected error during queued training job", exc_info=True)
            run_store.mark_finished(job_id, status="failed", result=f"failed: {exc}")


def run_worker() -> None:
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
    settings = Settings.from_env(base_dir=Path(__file__).resolve().parents[1])
    poll_seconds = Settings.positive_int_from_env("WORKER_POLL_SECONDS", 30)

    if settings.database_url and settings.redis_url and settings.object_storage_endpoint:
        _run_durable_worker(settings, poll_seconds)
        return

    logger.info(
        json.dumps(
            {
                "event": "worker.ready",
                "mode": "placeholder",
                "database_configured": settings.database_url is not None,
                "redis_configured": settings.redis_url is not None,
                "object_storage_configured": settings.object_storage_endpoint is not None,
                "poll_seconds": poll_seconds,
            }
        )
    )
    while True:
        time.sleep(poll_seconds)


if __name__ == "__main__":
    run_worker()
