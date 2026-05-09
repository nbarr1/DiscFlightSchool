import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from training_server import Settings


class SettingsTests(unittest.TestCase):
    def test_from_env_loads_defaults_and_required_key(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            with patch.dict(os.environ, {"APP_API_KEY": "test-key"}, clear=True):
                settings = Settings.from_env(base_dir=Path(tmpdir))

        self.assertEqual(settings.app_api_key, "test-key")
        self.assertEqual(settings.max_upload_bytes, 8 * 1024 * 1024)
        self.assertEqual(settings.training_timeout_seconds, 7200)
        self.assertEqual(settings.export_timeout_seconds, 600)
        self.assertEqual(settings.training_epochs, 50)
        self.assertEqual(settings.training_image_size, 640)
        self.assertEqual(settings.training_batch_size, 16)
        self.assertEqual(settings.cors_allow_origins, ())
        self.assertIsNone(settings.database_url)
        self.assertIsNone(settings.redis_url)
        self.assertIsNone(settings.object_storage_endpoint)
        self.assertTrue(settings.object_storage_secure)

    def test_from_env_loads_remote_training_overrides(self):
        env = {
            "APP_API_KEY": "test-key",
            "CORS_ALLOW_ORIGINS": "https://app.example, https://admin.example ",
            "MAX_UPLOAD_BYTES": "2048",
            "TRAINING_TIMEOUT_SECONDS": "123",
            "MODEL_EXPORT_TIMEOUT_SECONDS": "45",
            "TRAINING_EPOCHS": "7",
            "TRAINING_IMAGE_SIZE": "320",
            "TRAINING_BATCH_SIZE": "2",
            "DATABASE_URL": "postgresql://example/db",
            "REDIS_URL": "redis://example:6379/0",
            "OBJECT_STORAGE_ENDPOINT": "http://minio:9000",
            "OBJECT_STORAGE_BUCKET": "disc-flight-school",
            "OBJECT_STORAGE_ACCESS_KEY": "access",
            "OBJECT_STORAGE_SECRET_KEY": "secret",
            "OBJECT_STORAGE_SECURE": "false",
        }
        with tempfile.TemporaryDirectory() as tmpdir:
            with patch.dict(os.environ, env, clear=True):
                settings = Settings.from_env(base_dir=Path(tmpdir))

        self.assertEqual(settings.cors_allow_origins, ("https://app.example", "https://admin.example"))
        self.assertEqual(settings.max_upload_bytes, 2048)
        self.assertEqual(settings.training_timeout_seconds, 123)
        self.assertEqual(settings.export_timeout_seconds, 45)
        self.assertEqual(settings.training_epochs, 7)
        self.assertEqual(settings.training_image_size, 320)
        self.assertEqual(settings.training_batch_size, 2)
        self.assertEqual(settings.database_url, "postgresql://example/db")
        self.assertEqual(settings.redis_url, "redis://example:6379/0")
        self.assertEqual(settings.object_storage_endpoint, "http://minio:9000")
        self.assertEqual(settings.object_storage_bucket, "disc-flight-school")
        self.assertEqual(settings.object_storage_access_key, "access")
        self.assertEqual(settings.object_storage_secret_key, "secret")
        self.assertFalse(settings.object_storage_secure)

    def test_from_env_rejects_missing_key_and_invalid_values(self):
        with self.assertRaisesRegex(RuntimeError, "APP_API_KEY"):
            with patch.dict(os.environ, {}, clear=True):
                Settings.from_env()

        for name, value in [
            ("MAX_UPLOAD_BYTES", "0"),
            ("TRAINING_EPOCHS", "not-int"),
            ("OBJECT_STORAGE_SECURE", "maybe"),
        ]:
            with self.subTest(name=name):
                with self.assertRaisesRegex(RuntimeError, name):
                    with patch.dict(os.environ, {"APP_API_KEY": "test-key", name: value}, clear=True):
                        Settings.from_env()


if __name__ == "__main__":
    unittest.main()
