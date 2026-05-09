"""Placeholder worker entrypoint for the durable runtime stack."""

from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path

from .config import Settings

logger = logging.getLogger("disc_flight_school.training_server.worker")


def run_worker() -> None:
    """Validate runtime configuration and keep the worker container alive.

    Durable queue consumption is introduced in a later Phase 4 slice. This
    entrypoint lets the containerized API/worker/database/queue/object-storage
    stack be started and remotely validated before queue adapters are wired in.
    """
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
    settings = Settings.from_env(base_dir=Path(__file__).resolve().parents[1])
    poll_seconds = Settings.positive_int_from_env("WORKER_POLL_SECONDS", 30)
    logger.info(
        json.dumps(
            {
                "event": "worker.ready",
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
