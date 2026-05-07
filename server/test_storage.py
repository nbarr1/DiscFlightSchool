import tempfile
import unittest
from pathlib import Path

from training_server import Settings
from training_server.storage import FileStorage


class FileStorageTests(unittest.TestCase):
    def test_training_exports_use_unique_zip_paths(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            settings = Settings(app_api_key="test-key", base_dir=Path(tmpdir))
            storage = FileStorage(settings)
            storage.initialize()
            (settings.labels_dir / "sample.txt").write_text("0 0.5 0.5 0.1 0.1")

            first = storage.build_training_export()
            second = storage.build_training_export()

            self.assertNotEqual(first, second)
            self.assertEqual(first.suffix, ".zip")
            self.assertEqual(second.suffix, ".zip")
            self.assertTrue(first.exists())
            self.assertTrue(second.exists())


if __name__ == "__main__":
    unittest.main()
