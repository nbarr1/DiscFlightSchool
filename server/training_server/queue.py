"""Redis-backed training job queue and Postgres-backed cross-process run status.

Used only when a durable stack (Postgres + Redis) is configured. Local/dev
runs with no `REDIS_URL` never touch this module — training stays an
in-process thread, as it always has.
"""

from __future__ import annotations

import json
import uuid
from typing import Any

from psycopg.errors import UniqueViolation
from psycopg_pool import ConnectionPool
from redis import Redis


class RunAlreadyActiveError(Exception):
    """Raised by TrainingRunStore.create_run() when a run is already queued or running."""


class TrainingJobQueue:
    """A single Redis list used as a training job queue."""

    QUEUE_KEY = "training:jobs"

    def __init__(self, redis_client: Redis) -> None:
        self._redis = redis_client

    def enqueue(self, job_id: str) -> None:
        self._redis.lpush(self.QUEUE_KEY, json.dumps({"job_id": job_id}))

    def pop(self, timeout_seconds: int) -> str | None:
        """Block up to `timeout_seconds` for a job; None means the timeout elapsed."""
        result = self._redis.brpop([self.QUEUE_KEY], timeout=timeout_seconds)
        if result is None:
            return None
        _key, raw = result
        payload = json.loads(raw)
        return payload["job_id"]


class TrainingRunStore:
    """Cross-process training-run status, backed by the `training_runs` table.

    Replaces `TrainingManager`'s in-memory lock/status dict for the durable
    path: the partial unique index on `training_runs` is what actually
    enforces "only one run at a time" once training can be started from one
    process (the API) and executed in another (the worker).
    """

    def __init__(self, pool: ConnectionPool) -> None:
        self._pool = pool

    def create_run(self) -> str:
        run_id = str(uuid.uuid4())
        try:
            with self._pool.connection() as conn:
                conn.execute(
                    "INSERT INTO training_runs (id, status) VALUES (%s, 'queued')",
                    (run_id,),
                )
        except UniqueViolation as exc:
            raise RunAlreadyActiveError("Training is already in progress") from exc
        return run_id

    def mark_running(self, run_id: str) -> None:
        with self._pool.connection() as conn:
            conn.execute(
                "UPDATE training_runs SET status = 'running', started_at = now() WHERE id = %s",
                (run_id,),
            )

    def mark_finished(self, run_id: str, *, status: str, result: str) -> None:
        with self._pool.connection() as conn:
            conn.execute(
                "UPDATE training_runs SET status = %s, result = %s, finished_at = now() "
                "WHERE id = %s",
                (status, result, run_id),
            )

    def latest_status(self) -> dict[str, Any]:
        """Shaped identically to `TrainingManager.status` in non-durable mode,
        so `app.py`'s `get_training_status` handler needs no changes."""
        with self._pool.connection() as conn:
            row = conn.execute(
                "SELECT status, result, finished_at FROM training_runs "
                "ORDER BY enqueued_at DESC LIMIT 1"
            ).fetchone()
        if row is None:
            return {"running": False, "last_run": None, "result": None}
        status, result, finished_at = row
        return {
            "running": status in ("queued", "running"),
            "last_run": finished_at.isoformat() if finished_at else None,
            "result": result,
        }
