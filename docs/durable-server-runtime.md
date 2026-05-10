# Durable Server Runtime Status

Audited on 2026-05-10.

## What exists now

- `docker-compose.yml` defines `training-api`, `training-worker`, `postgres`, `redis`, `minio`, and `minio-init` services.
- `server/.env.example` documents the API key, training, database, Redis, object-storage, and worker-poll settings used by the compose scaffold.
- `Settings.from_env()` parses optional database, Redis, and object-storage values.
- `training_server.worker` validates those settings, logs a ready event, and sleeps in a loop.
- `scripts/validate_durable_runtime.py` checks that the compose file and env example contain required services/settings without requiring Docker.

## What does not exist yet

- No PostgreSQL metadata schema or migration files are implemented.
- No `StorageBackend` implementation uses PostgreSQL or S3-compatible object storage.
- No Redis queue producer/consumer is implemented.
- The worker does not execute training jobs or consume queue messages.
- Compose integration tests are not present.

## How to run the scaffold

```bash
cp server/.env.example server/.env
# Edit server/.env before production-like use.
docker compose --env-file server/.env up --build
```

Useful local endpoints after startup:

- API health: `http://localhost:8000/health`
- MinIO API: `http://localhost:9000`
- MinIO console: `http://localhost:9001`

## Next implementation steps

1. Add database schema/migrations for uploads, model artifacts, and training jobs.
2. Add an object-storage adapter that implements `StorageBackend`.
3. Add a Redis queue adapter and enqueue training-start requests.
4. Replace the placeholder worker loop with queue consumption and training execution.
5. Add compose-backed integration tests for API, worker, database, queue, and object storage.
