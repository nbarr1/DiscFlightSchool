#!/usr/bin/env python3
"""Validate durable runtime compose/config files without requiring Docker."""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMPOSE = ROOT / "docker-compose.yml"
ENV_EXAMPLE = ROOT / "server" / ".env.example"

REQUIRED_SERVICES = (
    "training-api",
    "training-worker",
    "postgres",
    "redis",
    "minio",
    "minio-init",
)
REQUIRED_ENV_KEYS = (
    "APP_API_KEY",
    "DATABASE_URL",
    "REDIS_URL",
    "OBJECT_STORAGE_ENDPOINT",
    "OBJECT_STORAGE_BUCKET",
    "OBJECT_STORAGE_ACCESS_KEY",
    "OBJECT_STORAGE_SECRET_KEY",
    "OBJECT_STORAGE_SECURE",
)


def main() -> None:
    compose = COMPOSE.read_text()
    env_example = ENV_EXAMPLE.read_text()

    missing_services = [service for service in REQUIRED_SERVICES if f"  {service}:" not in compose]
    if missing_services:
        raise SystemExit(f"Missing compose services: {', '.join(missing_services)}")

    missing_env = [key for key in REQUIRED_ENV_KEYS if f"{key}=" not in env_example]
    if missing_env:
        raise SystemExit(f"Missing .env.example keys: {', '.join(missing_env)}")

    forbidden_defaults = (
        "postgresql://discflight:discflight@",
        "POSTGRES_PASSWORD: discflight",
        "MINIO_ROOT_USER: minioadmin",
        "MINIO_ROOT_PASSWORD: minioadmin",
        "OBJECT_STORAGE_ACCESS_KEY: minioadmin",
        "OBJECT_STORAGE_SECRET_KEY: minioadmin",
    )
    found_defaults = [value for value in forbidden_defaults if value in compose]
    if found_defaults:
        raise SystemExit(
            "Compose file contains unsafe default credentials: "
            + ", ".join(found_defaults)
        )

    if "python -m training_server.worker" not in compose:
        raise SystemExit("training-worker must run the training_server.worker module")

    # The compose stack reads server/.env.example for defaults, so every secret
    # must additionally be a required shell override. Otherwise the committed
    # placeholder becomes a live credential the moment someone runs the stack.
    required_overrides = ("APP_API_KEY", "POSTGRES_PASSWORD", "MINIO_ROOT_PASSWORD")
    missing_overrides = [
        name for name in required_overrides if f"${{{name}:?" not in compose
    ]
    if missing_overrides:
        raise SystemExit(
            "Compose file must require these as shell overrides (${NAME:?...}), "
            "otherwise the .env.example placeholder is used: "
            + ", ".join(missing_overrides)
        )

    # Both services that run application code need the API key override, not
    # just the first one that happens to be defined.
    api_key_overrides = compose.count("APP_API_KEY: ${APP_API_KEY:?")
    if api_key_overrides < 2:
        raise SystemExit(
            "Both training-api and training-worker must override APP_API_KEY "
            f"(found {api_key_overrides} of 2)"
        )

    print("Durable runtime files validated.")


if __name__ == "__main__":
    main()
