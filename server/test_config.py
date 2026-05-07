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

    def test_from_env_rejects_missing_key_and_invalid_positive_ints(self):
        with self.assertRaisesRegex(RuntimeError, "APP_API_KEY"):
            with patch.dict(os.environ, {}, clear=True):
                Settings.from_env()

        for name, value in [("MAX_UPLOAD_BYTES", "0"), ("TRAINING_EPOCHS", "not-int")]:
            with self.subTest(name=name):
                with self.assertRaisesRegex(RuntimeError, name):
                    with patch.dict(os.environ, {"APP_API_KEY": "test-key", name: value}, clear=True):
                        Settings.from_env()


if __name__ == "__main__":
    unittest.main()
