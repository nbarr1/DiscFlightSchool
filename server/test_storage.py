"""FileStorage behaviour and the StorageBackend contract.

`assertIsInstance(storage, StorageBackend)` on a `runtime_checkable` Protocol
only checks that *method names* exist — it says nothing about signatures,
arguments, or return shapes. These tests exercise the actual behaviour any
durable adapter would have to reproduce.
"""

from __future__ import annotations

import io
import os
import tempfile
import unittest
import zipfile
from pathlib import Path

os.environ.setdefault("APP_API_KEY", "test-key")

from PIL import Image  # noqa: E402

from training_server import Settings, StorageBackend  # noqa: E402
from training_server.storage import FileStorage  # noqa: E402


def image_bytes(format_name: str, size: tuple[int, int] = (4, 4)) -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", size, color=(255, 0, 0)).save(buffer, format=format_name)
    return buffer.getvalue()


class StubUpload:
    """Stands in for starlette's UploadFile — storage only uses .file/.filename."""

    def __init__(self, filename: str, data: bytes) -> None:
        self.filename = filename
        self.file = io.BytesIO(data)


VALID_LABEL = "0 0.5 0.5 0.1 0.1"


def run_storage_backend_contract(
    storage: StorageBackend, settings: Settings, test_case: unittest.TestCase
) -> None:
    """Behavioural contract every StorageBackend implementation must satisfy."""
    storage.initialize()
    (settings.labels_dir / "sample.txt").write_text(VALID_LABEL)

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

    # Stats round-trip through whatever the backing store is.
    storage.save_stats({"total_samples": 7, "last_upload": "2026-01-01T00:00:00"})
    test_case.assertEqual(7, storage.load_stats()["total_samples"])

    storage.record_upload()
    test_case.assertEqual(8, storage.load_stats()["total_samples"])


class FileStorageContractTests(unittest.TestCase):
    def test_filesystem_storage_satisfies_storage_backend_contract(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            settings = Settings(app_api_key="test-key", base_dir=Path(tmpdir))
            storage = FileStorage(settings)

            self.assertIsInstance(storage, StorageBackend)
            run_storage_backend_contract(storage, settings, self)


class FileStorageBehaviourTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.settings = Settings(app_api_key="test-key", base_dir=Path(self._tmp.name))
        self.storage = FileStorage(self.settings)
        self.storage.initialize()

    def store(
        self,
        sample_id: str,
        *,
        full: bytes | None = None,
        crop: bytes | None = None,
        full_name: str = "a.jpg",
        crop_name: str = "b.jpg",
        label: str = VALID_LABEL,
    ) -> None:
        self.storage.store_training_sample(
            sample_id=sample_id,
            label=label,
            full_image=StubUpload(
                full_name, full if full is not None else image_bytes("JPEG")
            ),
            crop_image=StubUpload(
                crop_name, crop if crop is not None else image_bytes("JPEG")
            ),
        )

    # ---- initialize ----

    def test_initialize_creates_dataset_yaml_once(self):
        self.assertTrue(self.settings.dataset_yaml.exists())
        self.settings.dataset_yaml.write_text("custom: true\n")
        self.storage.initialize()
        self.assertEqual("custom: true\n", self.settings.dataset_yaml.read_text())

    # ---- store_training_sample ----

    def test_stores_full_crop_and_label(self):
        self.store("sample-1")

        self.assertTrue((self.settings.images_dir / "sample-1_full.jpg").exists())
        self.assertTrue((self.settings.images_dir / "sample-1_crop.jpg").exists())
        label_path = self.settings.labels_dir / "sample-1_full.txt"
        self.assertTrue(label_path.exists())
        self.assertEqual(VALID_LABEL, label_path.read_text())

        counts = self.storage.dataset_counts()
        self.assertEqual(1, counts["full_images"])
        self.assertEqual(2, counts["all_images"])
        self.assertEqual(1, counts["labels"])
        self.assertEqual(1, self.storage.load_stats()["total_samples"])

    def test_duplicate_sample_id_is_rejected(self):
        self.store("dupe")
        with self.assertRaises(ValueError) as ctx:
            self.store("dupe")
        self.assertIn("already exists", str(ctx.exception))
        # The first sample must survive the rejected retry.
        self.assertTrue((self.settings.images_dir / "dupe_full.jpg").exists())
        self.assertEqual(1, self.storage.load_stats()["total_samples"])

    def test_png_upload_keeps_png_extension(self):
        self.store(
            "png-sample",
            full=image_bytes("PNG"),
            crop=image_bytes("PNG"),
            full_name="a.png",
            crop_name="b.png",
        )
        self.assertTrue((self.settings.images_dir / "png-sample_full.png").exists())

    def test_extension_content_mismatch_is_rejected(self):
        # PNG bytes announced as .jpg — the signature check must catch it.
        with self.assertRaises(ValueError):
            self.store("liar", full=image_bytes("PNG"), full_name="a.jpg")
        self.assertEqual(0, self.storage.dataset_counts()["all_images"])

    def test_non_image_payload_is_rejected(self):
        with self.assertRaises(ValueError):
            self.store("evil", full=b"#!/bin/sh\nrm -rf /\n")
        self.assertEqual(0, self.storage.dataset_counts()["all_images"])

    def test_empty_upload_is_rejected(self):
        with self.assertRaises(ValueError):
            self.store("empty", full=b"")

    def test_oversize_upload_is_rejected_and_leaves_nothing_behind(self):
        small_limit = Settings(
            app_api_key="test-key",
            base_dir=Path(self._tmp.name),
            max_upload_bytes=32,
        )
        storage = FileStorage(small_limit)
        storage.initialize()

        with self.assertRaises(ValueError) as ctx:
            storage.store_training_sample(
                sample_id="huge",
                label=VALID_LABEL,
                full_image=StubUpload("a.jpg", image_bytes("JPEG", size=(256, 256))),
                crop_image=StubUpload("b.jpg", image_bytes("JPEG")),
            )
        self.assertIn("size limit", str(ctx.exception))
        self.assertEqual(0, storage.dataset_counts()["all_images"])

    def test_failed_store_leaves_no_temp_files(self):
        with self.assertRaises(ValueError):
            self.store("bad", crop=b"not an image")

        leftovers = [p.name for p in self.settings.images_dir.iterdir()]
        self.assertEqual([], leftovers, f"temp/partial files left behind: {leftovers}")
        self.assertEqual(
            [],
            [p.name for p in self.settings.labels_dir.glob("*.txt")],
        )

    def test_failed_store_releases_the_sample_id(self):
        with self.assertRaises(ValueError):
            self.store("retry-me", full=b"garbage")
        # A failed attempt must not permanently reserve the id via a stale
        # lock file.
        self.store("retry-me")
        self.assertTrue((self.settings.images_dir / "retry-me_full.jpg").exists())

    def test_decompression_bomb_is_a_value_error_not_a_crash(self):
        # Pillow raises DecompressionBombError, which is NOT an OSError, so it
        # used to escape store_training_sample as an unhandled 500. Storage must
        # translate it into a client error like any other bad upload.
        #
        # Squeezing MAX_IMAGE_PIXELS is how Pillow's own suite tests this — a
        # genuinely huge file is impractical, and hand-corrupting the IHDR
        # fails the chunk CRC first and never reaches the bomb check.
        original_limit = Image.MAX_IMAGE_PIXELS
        Image.MAX_IMAGE_PIXELS = 8
        try:
            with self.assertRaises(ValueError) as ctx:
                self.store(
                    "bomb",
                    full=image_bytes("PNG", size=(64, 64)),
                    full_name="a.png",
                )
        finally:
            Image.MAX_IMAGE_PIXELS = original_limit

        self.assertIn("decode limit", str(ctx.exception))
        # And nothing partial is left on disk.
        self.assertEqual([], [p.name for p in self.settings.images_dir.iterdir()])

    # ---- exports ----

    def test_export_contains_stored_sample(self):
        self.store("in-export")
        zip_path = self.storage.build_training_export()

        with zipfile.ZipFile(zip_path) as archive:
            names = archive.namelist()
        self.assertTrue(
            any("in-export_full.jpg" in name for name in names),
            f"stored image missing from export: {names}",
        )

    # ---- model info ----

    def test_latest_model_info_picks_newest_and_caches_hash(self):
        older = self.settings.models_dir / "disc_detector_v1.tflite"
        newer = self.settings.models_dir / "disc_detector_v2.tflite"
        older.write_bytes(b"old-model")
        newer.write_bytes(b"new-model")
        os.utime(older, (1_600_000_000, 1_600_000_000))
        os.utime(newer, (1_700_000_000, 1_700_000_000))

        info = self.storage.latest_model_info()
        self.assertIsNotNone(info)
        assert info is not None
        self.assertEqual("disc_detector_v2", info["version"])
        self.assertEqual(64, len(info["sha256"]))

        # Second call hits the cache and must return the same hash.
        cached = self.storage.latest_model_info()
        assert cached is not None
        self.assertEqual(info["sha256"], cached["sha256"])

    def test_latest_model_info_refreshes_when_the_file_changes(self):
        model = self.settings.models_dir / "disc_detector_v1.tflite"
        model.write_bytes(b"first")
        first = self.storage.latest_model_info()
        assert first is not None

        model.write_bytes(b"second-and-longer")
        os.utime(model, (1_800_000_000, 1_800_000_000))
        second = self.storage.latest_model_info()
        assert second is not None

        self.assertNotEqual(first["sha256"], second["sha256"])

    def test_latest_model_info_is_none_when_directory_is_empty(self):
        self.assertIsNone(self.storage.latest_model_info())

    # ---- stats ----

    def test_load_stats_defaults_when_file_absent(self):
        stats = self.storage.load_stats()
        self.assertEqual(0, stats["total_samples"])
        self.assertIsNone(stats["last_upload"])

    def test_save_stats_is_atomic_and_leaves_no_temp_files(self):
        self.storage.save_stats({"total_samples": 1, "last_upload": None})
        stray = list(self.settings.base_dir.glob("*.tmp"))
        self.assertEqual([], stray, f"temp stats files left behind: {stray}")


if __name__ == "__main__":
    unittest.main()
