import tempfile
import unittest
from pathlib import Path

from training_server import Settings, StorageBackend
from training_server.storage import FileStorage


def run_storage_backend_contract(storage: StorageBackend, settings: Settings, test_case: unittest.TestCase) -> None:
    storage.initialize()
    (settings.labels_dir / "sample.txt").write_text("0 0.5 0.5 0.1 0.1")

    counts = storage.dataset_counts()
    test_case.assertEqual(counts["labels"], 1)
    test_case.assertEqual(counts["all_images"], 0)
    test_case.assertIsNone(storage.latest_model_info())

    first = storage.build_training_export()
    second = storage.build_training_export()

    test_case.assertNotEqual(first, second)
    test_case.assertEqual(first.suffix, ".zip")
    test_case.assertEqual(second.suffix, ".zip")
    test_case.assertTrue(first.exists())
    test_case.assertTrue(second.exists())


class FileStorageTests(unittest.TestCase):
    def test_filesystem_storage_satisfies_storage_backend_contract(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            settings = Settings(app_api_key="test-key", base_dir=Path(tmpdir))
            storage = FileStorage(settings)

            self.assertIsInstance(storage, StorageBackend)
            run_storage_backend_contract(storage, settings, self)


if __name__ == "__main__":
    unittest.main()
