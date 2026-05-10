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

    if "python -m training_server.worker" not in compose:
        raise SystemExit("training-worker must run the training_server.worker module")

    print("Durable runtime files validated.")


if __name__ == "__main__":
    main()
