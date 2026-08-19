"""PostgresMinioStorage against real Postgres/MinIO.

Skipped locally when DATABASE_URL/OBJECT_STORAGE_* aren't set — `pytest server`
with no services configured must still pass (see scripts/test_server.sh). CI
provides real services via a `services:` block (see server-tests.yml's
test-server-durable job) so this actually runs against Postgres/MinIO, not
mocks.
"""

from __future__ import annotations

import io
import os
import tempfile
import unittest
import uuid
from pathlib import Path

os.environ.setdefault("APP_API_KEY", "test-key")

from PIL import Image  # noqa: E402

from test_storage import StubUpload, VALID_LABEL, image_bytes, run_storage_backend_contract  # noqa: E402
from training_server import Settings, StorageBackend  # noqa: E402

DURABLE_ENV_VARS = (
    "DATABASE_URL",
    "OBJECT_STORAGE_ENDPOINT",
    "OBJECT_STORAGE_BUCKET",
    "OBJECT_STORAGE_ACCESS_KEY",
    "OBJECT_STORAGE_SECRET_KEY",
)
DURABLE_CONFIGURED = all(os.environ.get(name) for name in DURABLE_ENV_VARS)


def _settings(base_dir: Path) -> Settings:
    return Settings(
        app_api_key="test-key",
        base_dir=base_dir,
        database_url=os.environ["DATABASE_URL"],
        object_storage_endpoint=os.environ["OBJECT_STORAGE_ENDPOINT"],
        object_storage_bucket=os.environ["OBJECT_STORAGE_BUCKET"],
        object_storage_access_key=os.environ["OBJECT_STORAGE_ACCESS_KEY"],
        object_storage_secret_key=os.environ["OBJECT_STORAGE_SECRET_KEY"],
        object_storage_secure=os.environ.get("OBJECT_STORAGE_SECURE", "false").lower() == "true",
    )


@unittest.skipUnless(DURABLE_CONFIGURED, "durable storage env vars not configured")
class PostgresMinioStorageContractTests(unittest.TestCase):
    def test_durable_storage_satisfies_storage_backend_contract(self):
        from training_server.durable_storage import PostgresMinioStorage

        with tempfile.TemporaryDirectory() as tmpdir:
            settings = _settings(Path(tmpdir))
            storage = PostgresMinioStorage(settings)

            self.assertIsInstance(storage, StorageBackend)
            run_storage_backend_contract(storage, settings, self)


@unittest.skipUnless(DURABLE_CONFIGURED, "durable storage env vars not configured")
class PostgresMinioStorageBehaviourTests(unittest.TestCase):
    def setUp(self) -> None:
        from training_server.durable_storage import PostgresMinioStorage

        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.settings = _settings(Path(self._tmp.name))
        self.storage = PostgresMinioStorage(self.settings)
        self.storage.initialize()

    def _sample_id(self) -> str:
        return f"durable-{uuid.uuid4().hex[:12]}"

    def store(self, sample_id: str) -> None:
        self.storage.store_training_sample(
            sample_id=sample_id,
            label=VALID_LABEL,
            full_image=StubUpload("a.jpg", image_bytes("JPEG")),
            crop_image=StubUpload("b.jpg", image_bytes("JPEG")),
        )

    def test_duplicate_sample_id_is_rejected_and_first_survives(self):
        sample_id = self._sample_id()
        self.store(sample_id)
        with self.assertRaises(ValueError) as ctx:
            self.store(sample_id)
        self.assertIn("already exists", str(ctx.exception))

        dataset_dir = self.storage.materialize_dataset()
        matches = list((dataset_dir / "images" / "train").glob(f"{sample_id}_full.*"))
        self.assertEqual(1, len(matches))

    def test_materialize_dataset_produces_a_valid_yolo_tree(self):
        sample_id = self._sample_id()
        self.store(sample_id)

        dataset_dir = self.storage.materialize_dataset()
        self.assertTrue((dataset_dir / "dataset.yaml").exists())
        self.assertTrue(list((dataset_dir / "images" / "train").glob(f"{sample_id}_full.*")))
        self.assertTrue(list((dataset_dir / "images" / "train").glob(f"{sample_id}_crop.*")))
        label_path = dataset_dir / "labels" / "train" / f"{sample_id}_full.txt"
        self.assertTrue(label_path.exists())
        self.assertEqual(VALID_LABEL, label_path.read_text())

    def test_publish_model_round_trips_through_minio(self):
        with tempfile.NamedTemporaryFile(suffix=".tflite", delete=False) as tmp:
            tmp.write(b"round-trip-bytes")
            tmp_path = Path(tmp.name)
        try:
            version = f"v-{uuid.uuid4().hex[:8]}"
            published = self.storage.publish_model(tmp_path, version=version)
        finally:
            tmp_path.unlink(missing_ok=True)

        # Force a MinIO round trip: delete the local cache copy and confirm
        # latest_model_info() re-downloads it rather than returning None.
        published["path"].unlink()
        info = self.storage.latest_model_info()
        self.assertIsNotNone(info)
        assert info is not None
        self.assertEqual(version, info["version"])
        self.assertEqual(published["sha256"], info["sha256"])
        self.assertEqual(b"round-trip-bytes", info["path"].read_bytes())

    def test_extension_content_mismatch_is_rejected(self):
        with self.assertRaises(ValueError):
            self.storage.store_training_sample(
                sample_id=self._sample_id(),
                label=VALID_LABEL,
                full_image=StubUpload("a.jpg", image_bytes("PNG")),
                crop_image=StubUpload("b.jpg", image_bytes("JPEG")),
            )


if __name__ == "__main__":
    unittest.main()
