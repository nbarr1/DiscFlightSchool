"""Configuration loading for the training server."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


TRAINING_IMAGE_LIST = "train.txt"

# Every variable durable mode needs, by the Settings field that holds it.
DURABLE_STORAGE_ENV = {
    "DATABASE_URL": "database_url",
    "REDIS_URL": "redis_url",
    "OBJECT_STORAGE_ENDPOINT": "object_storage_endpoint",
    "OBJECT_STORAGE_BUCKET": "object_storage_bucket",
    "OBJECT_STORAGE_ACCESS_KEY": "object_storage_access_key",
    "OBJECT_STORAGE_SECRET_KEY": "object_storage_secret_key",
}


def render_dataset_yaml(dataset_dir: Path) -> str:
    """YOLO dataset manifest shared by every StorageBackend that assembles a
    local training-ready directory (FileStorage's `dataset_dir`, or a durable
    adapter's materialized copy).

    It points at the image list `write_training_image_list` writes rather than
    at `images/train`, because that folder also holds each sample's crop.
    Crops carry no label, and YOLO trains on an unlabelled image as background,
    so pointing it at the folder would teach it that a close-up of a disc is
    not a disc.
    """
    return (
        f"path: {dataset_dir.resolve()}\n"
        f"train: {TRAINING_IMAGE_LIST}\n"
        f"val: {TRAINING_IMAGE_LIST}\n"
        "\n"
        "names:\n"
        "  0: disc\n"
    )


def is_legacy_dataset_yaml(text: str, dataset_dir: Path) -> bool:
    """Whether `text` is the manifest earlier releases generated, which
    trained on the whole of `images/train`, crops included. An operator's own
    edits never match, so only an untouched default is ever replaced."""
    legacy = (
        f"path: {dataset_dir.resolve()}\n"
        "train: images/train\n"
        "val: images/train\n"
        "\n"
        "names:\n"
        "  0: disc\n"
    )
    return text == legacy


def write_training_image_list(dataset_dir: Path) -> Path:
    """Write the list of labelled full frames that `render_dataset_yaml` names.

    Entries are `./`-relative, which ultralytics resolves against the list's
    own folder, so an exported copy of the dataset still trains elsewhere.
    """
    images_dir = dataset_dir / "images" / "train"
    names = sorted(
        path.name
        for path in images_dir.glob("*_full.*")
        # Skips an upload still being written, which FileStorage names
        # `.<final name>.<random>.tmp` until it is complete.
        if path.is_file() and not path.name.startswith(".")
        and path.suffix.lower() in {".jpg", ".jpeg", ".png"}
    )
    list_path = dataset_dir / TRAINING_IMAGE_LIST
    list_path.write_text("".join(f"./images/train/{name}\n" for name in names))
    return list_path


@dataclass(frozen=True)
class Settings:
    """Runtime configuration for the FastAPI training server."""

    app_api_key: str
    base_dir: Path
    cors_allow_origins: tuple[str, ...] = ()
    max_upload_bytes: int = 8 * 1024 * 1024
    training_timeout_seconds: int = 7200
    export_timeout_seconds: int = 600
    training_epochs: int = 50
    training_image_size: int = 640
    training_batch_size: int = 16
    database_url: str | None = None
    redis_url: str | None = None
    object_storage_endpoint: str | None = None
    object_storage_bucket: str | None = None
    object_storage_access_key: str | None = None
    object_storage_secret_key: str | None = None
    object_storage_secure: bool = True
    roboflow_api_key: str | None = None
    # A key the Android app ships with. It is accepted only by the Roboflow
    # detection endpoints, never by the training or export ones, because
    # anyone with the app can extract it.
    client_api_key: str | None = None
    # A key that opens only POST /api/training/upload, for contributors who
    # should add samples without being able to export the dataset or start
    # training runs.
    upload_api_key: str | None = None
    disc_flight_max_upload_bytes: int = 200 * 1024 * 1024
    disc_flight_session_timeout_seconds: int = 900
    # Video jobs running at once, across every caller. Each holds a Roboflow
    # session and up to one upload's worth of disk.
    disc_flight_max_active_jobs: int = 3
    # Roboflow requests (new video jobs and single-image detections) made with
    # the client key, per caller IP and across all callers, in any hour. The
    # client key ships in the app, so these bound what anyone holding it can
    # spend. Requests with APP_API_KEY are not counted.
    client_rate_limit_per_hour: int = 30
    client_global_limit_per_hour: int = 300
    # Proxies in front of the server that append to X-Forwarded-For. With 1
    # (Render, or one Cloudflare Tunnel), the caller IP is the last entry;
    # entries further left are whatever the caller sent and are never trusted.
    # 0 uses the socket's peer address.
    trusted_proxy_hops: int = 0

    @property
    def uses_durable_storage(self) -> bool:
        """Whether every durable-mode variable is set.

        Raises when only some are, rather than falling back to the filesystem
        and silently keeping production data on a disk that may not persist.
        """
        missing = [env for env, field in DURABLE_STORAGE_ENV.items() if not getattr(self, field)]
        if not missing:
            return True
        if len(missing) == len(DURABLE_STORAGE_ENV):
            return False
        raise RuntimeError(
            "Durable storage is only partly configured. Set "
            + ", ".join(missing)
            + ", or unset the other durable variables to use filesystem storage."
        )

    @property
    def dataset_dir(self) -> Path:
        return self.base_dir / "dataset"

    @property
    def images_dir(self) -> Path:
        return self.dataset_dir / "images" / "train"

    @property
    def labels_dir(self) -> Path:
        return self.dataset_dir / "labels" / "train"

    @property
    def models_dir(self) -> Path:
        return self.base_dir / "models"

    @property
    def export_dir(self) -> Path:
        return self.base_dir / "exports"

    @property
    def stats_file(self) -> Path:
        return self.base_dir / "stats.json"

    @property
    def dataset_yaml(self) -> Path:
        return self.dataset_dir / "dataset.yaml"

    @staticmethod
    def _optional_env(name: str) -> str | None:
        value = os.environ.get(name)
        if value is None or value.strip() == "":
            return None
        return value.strip()

    @staticmethod
    def _bool_from_env(name: str, default: bool) -> bool:
        raw = os.environ.get(name)
        if raw is None or raw.strip() == "":
            return default
        normalized = raw.strip().lower()
        if normalized in {"1", "true", "yes", "on"}:
            return True
        if normalized in {"0", "false", "no", "off"}:
            return False
        raise RuntimeError(f"{name} must be a boolean value")

    @staticmethod
    def non_negative_int_from_env(name: str, default: int) -> int:
        raw = os.environ.get(name, str(default))
        try:
            value = int(raw)
        except ValueError as exc:
            raise RuntimeError(f"{name} must be 0 or a positive integer") from exc
        if value < 0:
            raise RuntimeError(f"{name} must be 0 or a positive integer")
        return value

    @staticmethod
    def positive_int_from_env(name: str, default: int) -> int:
        raw = os.environ.get(name, str(default))
        try:
            value = int(raw)
        except ValueError as exc:
            raise RuntimeError(f"{name} must be a positive integer") from exc
        if value <= 0:
            raise RuntimeError(f"{name} must be a positive integer")
        return value

    @classmethod
    def from_env(cls, *, base_dir: Path | None = None) -> "Settings":
        app_api_key = os.environ.get("APP_API_KEY")
        if not app_api_key:
            raise RuntimeError("APP_API_KEY must be set before starting the training server")

        origins = tuple(
            origin.strip()
            for origin in os.environ.get("CORS_ALLOW_ORIGINS", "").split(",")
            if origin.strip()
        )
        max_upload_bytes = cls.positive_int_from_env("MAX_UPLOAD_BYTES", 8 * 1024 * 1024)
        training_timeout_seconds = cls.positive_int_from_env("TRAINING_TIMEOUT_SECONDS", 7200)
        export_timeout_seconds = cls.positive_int_from_env("MODEL_EXPORT_TIMEOUT_SECONDS", 600)
        training_epochs = cls.positive_int_from_env("TRAINING_EPOCHS", 50)
        training_image_size = cls.positive_int_from_env("TRAINING_IMAGE_SIZE", 640)
        training_batch_size = cls.positive_int_from_env("TRAINING_BATCH_SIZE", 16)
        object_storage_secure = cls._bool_from_env("OBJECT_STORAGE_SECURE", True)
        return cls(
            app_api_key=app_api_key,
            base_dir=base_dir or Path(__file__).resolve().parents[1],
            cors_allow_origins=origins,
            max_upload_bytes=max_upload_bytes,
            training_timeout_seconds=training_timeout_seconds,
            export_timeout_seconds=export_timeout_seconds,
            training_epochs=training_epochs,
            training_image_size=training_image_size,
            training_batch_size=training_batch_size,
            database_url=cls._optional_env("DATABASE_URL"),
            redis_url=cls._optional_env("REDIS_URL"),
            object_storage_endpoint=cls._optional_env("OBJECT_STORAGE_ENDPOINT"),
            object_storage_bucket=cls._optional_env("OBJECT_STORAGE_BUCKET"),
            object_storage_access_key=cls._optional_env("OBJECT_STORAGE_ACCESS_KEY"),
            object_storage_secret_key=cls._optional_env("OBJECT_STORAGE_SECRET_KEY"),
            object_storage_secure=object_storage_secure,
            roboflow_api_key=cls._optional_env("ROBOFLOW_API_KEY"),
            client_api_key=cls._optional_env("CLIENT_API_KEY"),
            upload_api_key=cls._optional_env("UPLOAD_API_KEY"),
            disc_flight_max_upload_bytes=cls.positive_int_from_env(
                "DISC_FLIGHT_MAX_UPLOAD_BYTES", 200 * 1024 * 1024
            ),
            disc_flight_session_timeout_seconds=cls.positive_int_from_env(
                "DISC_FLIGHT_SESSION_TIMEOUT_SECONDS", 900
            ),
            disc_flight_max_active_jobs=cls.positive_int_from_env(
                "DISC_FLIGHT_MAX_ACTIVE_JOBS", 3
            ),
            client_rate_limit_per_hour=cls.positive_int_from_env(
                "CLIENT_RATE_LIMIT_PER_HOUR", 30
            ),
            client_global_limit_per_hour=cls.positive_int_from_env(
                "CLIENT_GLOBAL_LIMIT_PER_HOUR", 300
            ),
            trusted_proxy_hops=cls.non_negative_int_from_env("TRUSTED_PROXY_HOPS", 0),
        )
