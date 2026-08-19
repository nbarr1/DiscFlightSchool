"""TrainingJobQueue / TrainingRunStore against real Redis/Postgres.

Skipped locally when DATABASE_URL/REDIS_URL aren't set, same as
test_durable_storage.py — see that file's module docstring.
"""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

os.environ.setdefault("APP_API_KEY", "test-key")

QUEUE_ENV_VARS = ("DATABASE_URL", "REDIS_URL")
QUEUE_CONFIGURED = all(os.environ.get(name) for name in QUEUE_ENV_VARS)


@unittest.skipUnless(QUEUE_CONFIGURED, "DATABASE_URL/REDIS_URL not configured")
class TrainingJobQueueTests(unittest.TestCase):
    def setUp(self) -> None:
        from redis import Redis

        from training_server.queue import TrainingJobQueue

        self.redis = Redis.from_url(os.environ["REDIS_URL"])
        self.redis.delete(TrainingJobQueue.QUEUE_KEY)
        self.addCleanup(self.redis.delete, TrainingJobQueue.QUEUE_KEY)
        self.queue = TrainingJobQueue(self.redis)

    def test_enqueue_then_pop_round_trips_the_job_id(self):
        self.queue.enqueue("job-123")
        self.assertEqual("job-123", self.queue.pop(5))

    def test_pop_returns_none_on_timeout_when_empty(self):
        self.assertIsNone(self.queue.pop(1))

    def test_pop_is_fifo_for_multiple_jobs(self):
        self.queue.enqueue("first")
        self.queue.enqueue("second")
        self.assertEqual("first", self.queue.pop(5))
        self.assertEqual("second", self.queue.pop(5))


@unittest.skipUnless(QUEUE_CONFIGURED, "DATABASE_URL/REDIS_URL not configured")
class TrainingRunStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        from psycopg_pool import ConnectionPool

        from training_server.config import Settings
        from training_server.durable_storage import PostgresMinioStorage
        from training_server.queue import TrainingRunStore

        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)

        self.pool = ConnectionPool(
            os.environ["DATABASE_URL"],
            kwargs={"autocommit": True},
            min_size=1,
            max_size=5,
            open=True,
        )
        self.addCleanup(self.pool.close)

        # Reuse PostgresMinioStorage.initialize() to create the schema —
        # object-storage config isn't exercised by these tests, but the
        # constructor requires it, so fall back to disposable placeholders
        # when it's not set (only training_runs is touched here).
        settings = Settings(
            app_api_key="test-key",
            base_dir=Path(self._tmp.name),
            database_url=os.environ["DATABASE_URL"],
            object_storage_endpoint=os.environ.get("OBJECT_STORAGE_ENDPOINT", "http://localhost:9000"),
            object_storage_bucket=os.environ.get("OBJECT_STORAGE_BUCKET", "disc-flight-school"),
            object_storage_access_key=os.environ.get("OBJECT_STORAGE_ACCESS_KEY", "placeholder"),
            object_storage_secret_key=os.environ.get("OBJECT_STORAGE_SECRET_KEY", "placeholder"),
            object_storage_secure=os.environ.get("OBJECT_STORAGE_SECURE", "false").lower() == "true",
        )
        storage = PostgresMinioStorage(settings, pool=self.pool)
        with self.pool.connection() as conn:
            conn.execute("DROP TABLE IF EXISTS training_runs")
        storage.initialize()
        with self.pool.connection() as conn:
            conn.execute("TRUNCATE training_runs")

        self.run_store = TrainingRunStore(self.pool)

    def test_latest_status_with_no_runs(self):
        self.assertEqual(
            {"running": False, "last_run": None, "result": None},
            self.run_store.latest_status(),
        )

    def test_create_run_then_create_run_again_conflicts(self):
        from training_server.queue import RunAlreadyActiveError

        self.run_store.create_run()
        with self.assertRaises(RunAlreadyActiveError):
            self.run_store.create_run()

    def test_mark_finished_allows_a_new_run_to_be_created(self):
        run_id = self.run_store.create_run()
        self.run_store.mark_running(run_id)
        self.run_store.mark_finished(run_id, status="success", result="success: v1")

        status = self.run_store.latest_status()
        self.assertFalse(status["running"])
        self.assertEqual("success: v1", status["result"])
        self.assertIsNotNone(status["last_run"])

        # No RunAlreadyActiveError now that the previous run is finished.
        self.run_store.create_run()


if __name__ == "__main__":
    unittest.main()
