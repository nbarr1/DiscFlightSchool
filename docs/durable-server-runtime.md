# Durable Server Runtime Scaffold

This document records the first Step 7 slice for running the training server with durable service dependencies in a remote or local virtual environment.

## Implemented Runtime Scaffold

- Root `docker-compose.yml` starts the training API, a worker container, PostgreSQL, Redis, MinIO, and a MinIO bucket initializer.
- `server/.env.example` documents all API, training, database, queue, and object-storage environment variables used by the compose stack.
- `Settings` now parses optional `DATABASE_URL`, `REDIS_URL`, and S3-compatible object-storage configuration.
- `training_server.worker` validates runtime configuration and keeps the worker container alive until durable queue consumption is implemented.
- `scripts/validate_durable_runtime.py` verifies the compose and environment-template files without requiring Docker.

## Run Locally

```bash
cp server/.env.example server/.env
# Replace APP_API_KEY and any local credentials before production-like use.
docker compose --env-file server/.env up --build
```

Useful endpoints once the stack is running:

- API: <http://localhost:8000/health>
- MinIO API: <http://localhost:9000>
- MinIO console: <http://localhost:9001>

## Remaining Durable Runtime Work

- Add PostgreSQL metadata schema and Alembic migrations.
- Add S3-compatible object-storage adapter implementing `StorageBackend`.
- Add Redis-backed queue adapter and replace the placeholder worker loop with real job consumption.
- Add Docker Compose integration tests that exercise API/worker/database/queue/object-storage boundaries.
