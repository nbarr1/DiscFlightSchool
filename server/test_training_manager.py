"""TrainingManager start/stop state machine.

The regression these cover: `start()` set `running = True` inside the lock and
then did work outside it. Any failure between those two points (a storage error,
a thread that could not be spawned) left `running` stuck True, and every later
POST /api/training/start returned 409 until the process was restarted.
"""

from __future__ import annotations

import os
import tempfile
import threading
import unittest
from pathlib import Path
from typing import Any

os.environ.setdefault("APP_API_KEY", "test-key")

from training_server import Settings  # noqa: E402
from training_server.training import TrainingManager  # noqa: E402


class FakeStorage:
    """Minimal StorageBackend stand-in for the counts TrainingManager reads."""

    def __init__(self, full_images: int = 0, raises: Exception | None = None) -> None:
        self._full_images = full_images
        self._raises = raises
        self.counts_calls = 0

    def dataset_counts(self) -> dict[str, int]:
        self.counts_calls += 1
        if self._raises is not None:
            raise self._raises
        return {
            "full_images": self._full_images,
            "all_images": self._full_images,
            "labels": self._full_images,
        }


class TrainingManagerStartTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.settings = Settings(app_api_key="test-key", base_dir=Path(self._tmp.name))

    def _manager(self, storage: Any) -> TrainingManager:
        manager = TrainingManager(self.settings, storage)
        # Never spawn a real `yolo` subprocess from a unit test.
        manager._run_training = lambda: None  # type: ignore[method-assign]
        return manager

    def test_insufficient_data_releases_the_running_flag(self):
        manager = self._manager(FakeStorage(full_images=3))

        payload, status = manager.start()

        self.assertEqual(400, status)
        self.assertEqual("insufficient_data", payload["status"])
        self.assertEqual(3, payload["count"])
        self.assertFalse(
            manager.status["running"],
            "a rejected start must not leave the manager marked running",
        )

    def test_insufficient_data_can_be_retried_after_more_uploads(self):
        storage = FakeStorage(full_images=3)
        manager = self._manager(storage)

        _, first_status = manager.start()
        self.assertEqual(400, first_status)

        # More samples arrive; the endpoint must accept a second attempt
        # rather than reporting 409 forever.
        storage._full_images = 12
        payload, second_status = manager.start()

        self.assertEqual(200, second_status)
        self.assertEqual("started", payload["status"])

    def test_storage_failure_releases_the_running_flag(self):
        storage = FakeStorage(raises=OSError("dataset directory unreadable"))
        manager = self._manager(storage)

        payload, status = manager.start()

        self.assertEqual(500, status)
        self.assertEqual("error", payload["status"])
        self.assertFalse(
            manager.status["running"],
            "a storage failure must not wedge the manager in the running state",
        )
        self.assertIn("failed to start", str(manager.status["result"]))

    def test_storage_failure_is_recoverable(self):
        storage = FakeStorage(raises=OSError("transient"))
        manager = self._manager(storage)

        _, failed_status = manager.start()
        self.assertEqual(500, failed_status)

        storage._raises = None
        storage._full_images = 25
        payload, status = manager.start()

        self.assertEqual(200, status)
        self.assertEqual("started", payload["status"])

    def test_thread_spawn_failure_releases_the_running_flag(self):
        manager = self._manager(FakeStorage(full_images=50))

        original_start = threading.Thread.start

        def boom(self):  # noqa: ANN001
            raise RuntimeError("can't start new thread")

        threading.Thread.start = boom  # type: ignore[method-assign]
        try:
            payload, status = manager.start()
        finally:
            threading.Thread.start = original_start  # type: ignore[method-assign]

        self.assertEqual(500, status)
        self.assertEqual("error", payload["status"])
        self.assertFalse(manager.status["running"])

    def test_concurrent_start_is_rejected_with_409(self):
        manager = self._manager(FakeStorage(full_images=50))

        # Hold the manager in the running state as a real in-flight job would.
        with manager._lock:
            manager._status["running"] = True

        payload, status = manager.start()

        self.assertEqual(409, status)
        self.assertEqual("already_running", payload["status"])

    def test_rejected_concurrent_start_does_not_read_storage(self):
        storage = FakeStorage(full_images=50)
        manager = self._manager(storage)
        with manager._lock:
            manager._status["running"] = True

        manager.start()

        self.assertEqual(
            0,
            storage.counts_calls,
            "the 409 path should short-circuit before touching storage",
        )

    def test_status_is_a_copy_not_the_live_dict(self):
        manager = self._manager(FakeStorage(full_images=1))

        snapshot = manager.status
        snapshot["running"] = True

        self.assertFalse(
            manager.status["running"],
            "status must hand out a copy so callers cannot mutate internal state",
        )


class FakeJobQueue:
    """Minimal TrainingJobQueue stand-in — no real Redis needed."""

    def __init__(self) -> None:
        self.enqueued: list[str] = []

    def enqueue(self, job_id: str) -> None:
        self.enqueued.append(job_id)


class FakeRunStore:
    """Minimal TrainingRunStore stand-in — no real Postgres needed."""

    def __init__(self, *, active: bool = False) -> None:
        self._active = active
        self._status: dict[str, Any] = {"running": False, "last_run": None, "result": None}
        self.create_run_calls = 0

    def create_run(self) -> str:
        from training_server.queue import RunAlreadyActiveError

        self.create_run_calls += 1
        if self._active:
            raise RunAlreadyActiveError("Training is already in progress")
        self._active = True
        self._status["running"] = True
        return "fake-run-id"

    def latest_status(self) -> dict[str, Any]:
        return self._status.copy()


class TrainingManagerDurableModeTests(unittest.TestCase):
    """`start()`/`status` when a job_queue + run_store are supplied — the
    Redis-queued path used when the durable stack is configured. Must not
    spawn a thread or touch the in-memory `_status` dict at all.
    """

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.settings = Settings(app_api_key="test-key", base_dir=Path(self._tmp.name))

    def _manager(self, storage: Any, *, run_store: FakeRunStore | None = None) -> tuple[
        TrainingManager, FakeJobQueue, FakeRunStore
    ]:
        job_queue = FakeJobQueue()
        run_store = run_store or FakeRunStore()
        manager = TrainingManager(
            self.settings, storage, job_queue=job_queue, run_store=run_store
        )
        return manager, job_queue, run_store

    def test_start_enqueues_instead_of_spawning_a_thread(self):
        manager, job_queue, run_store = self._manager(FakeStorage(full_images=12))

        original_start = threading.Thread.start

        def boom(self):  # noqa: ANN001
            raise AssertionError("durable start() must not spawn a thread")

        threading.Thread.start = boom  # type: ignore[method-assign]
        try:
            payload, status = manager.start()
        finally:
            threading.Thread.start = original_start  # type: ignore[method-assign]

        self.assertEqual(200, status)
        self.assertEqual("started", payload["status"])
        self.assertEqual(["fake-run-id"], job_queue.enqueued)

    def test_insufficient_data_short_circuits_before_creating_a_run(self):
        manager, job_queue, run_store = self._manager(FakeStorage(full_images=3))

        payload, status = manager.start()

        self.assertEqual(400, status)
        self.assertEqual("insufficient_data", payload["status"])
        self.assertEqual([], job_queue.enqueued)
        self.assertEqual(0, run_store.create_run_calls)

    def test_active_run_is_rejected_with_409(self):
        run_store = FakeRunStore(active=True)
        manager, job_queue, _ = self._manager(FakeStorage(full_images=50), run_store=run_store)

        payload, status = manager.start()

        self.assertEqual(409, status)
        self.assertEqual("already_running", payload["status"])
        self.assertEqual([], job_queue.enqueued)

    def test_status_reads_through_the_run_store(self):
        manager, _, run_store = self._manager(FakeStorage(full_images=50))
        run_store._status = {"running": True, "last_run": None, "result": None}

        self.assertEqual(run_store._status, manager.status)


if __name__ == "__main__":
    unittest.main()
