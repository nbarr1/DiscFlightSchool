# Disc Flight School Training Server

This directory contains the FastAPI training/model-distribution server for DiscFlightSchool. This README reflects the current source tree as audited on 2026-08-19.

## Runtime shape

- `main.py` is the deployment entrypoint and creates `app` from `training_server.create_app()`.
- `training_server/config.py` loads required and optional environment variables.
- `training_server/app.py` defines the HTTP routes. `create_app()` selects the storage/training backend automatically: `PostgresMinioStorage` + a Redis-queued `TrainingManager` when `DATABASE_URL`, `REDIS_URL`, and every `OBJECT_STORAGE_*` variable are set, otherwise `FileStorage` + an in-process-thread `TrainingManager` (local dev, no infra required).
- `training_server/storage.py` implements `FileStorage`, the filesystem-backed adapter (dataset dir, JSON stats file, local `.tflite` models).
- `training_server/durable_storage.py` implements `PostgresMinioStorage`: sample/model metadata in PostgreSQL, image/model bytes in MinIO. See "Durable storage" below for the schema and object-key layout.
- `training_server/queue.py` implements `TrainingJobQueue` (a Redis list) and `TrainingRunStore` (Postgres-backed cross-process run status), used only in durable mode.
- `training_server/training_job.py` runs the actual `yolo detect train` / `yolo export format=tflite` subprocess sequence — shared by both the in-process thread path and the worker's queue-consumption path, so it exists exactly once.
- `training_server/training.py`'s `TrainingManager` starts training either as an in-process thread (default) or by enqueuing a job for the worker (durable mode); both paths expose the same `start()`/`status` shapes.
- `training_server/validation.py` validates sample IDs, YOLO labels, file extensions, signatures, decodability, and safe child paths — shared by every storage backend.
- `training_server/worker.py` is a real Redis-queue consumer when the durable stack is configured (pops a job, runs training, publishes the model, records status); it falls back to the original placeholder (log config booleans and sleep) when it isn't, so `docker compose up` with the durable vars unset still behaves predictably.

## Environment variables

| Variable | Required | Default | Current use |
|---|---:|---|---|
| `APP_API_KEY` | Yes | none | Required at server startup and checked by upload/export/training-start endpoints. |
| `CORS_ALLOW_ORIGINS` | No | empty | Comma-separated origins for FastAPI CORS middleware. |
| `MAX_UPLOAD_BYTES` | No | `8388608` | Maximum bytes per uploaded image file. |
| `TRAINING_TIMEOUT_SECONDS` | No | `7200` | Timeout for `yolo detect train`. |
| `MODEL_EXPORT_TIMEOUT_SECONDS` | No | `600` | Timeout for `yolo export`. |
| `TRAINING_EPOCHS` | No | `50` | Epoch count passed to YOLO training. |
| `TRAINING_IMAGE_SIZE` | No | `640` | Image size passed to YOLO training/export. |
| `TRAINING_BATCH_SIZE` | No | `16` | Batch size passed to YOLO training. |
| `DATABASE_URL` | No | none | PostgreSQL connection string. When set together with `REDIS_URL` and every `OBJECT_STORAGE_*` variable, selects the durable storage/queue backend instead of the filesystem/in-process one. |
| `REDIS_URL` | No | none | Redis connection string for the training job queue (see "Durable storage" below). |
| `OBJECT_STORAGE_ENDPOINT` | No | none | MinIO/S3-compatible endpoint URL for image and model bytes. |
| `OBJECT_STORAGE_BUCKET` | No | none | Bucket used for dataset images and trained models. |
| `OBJECT_STORAGE_ACCESS_KEY` | No | none | Object storage access key. |
| `OBJECT_STORAGE_SECRET_KEY` | No | none | Object storage secret key. |
| `OBJECT_STORAGE_SECURE` | No | `true` | Whether the object storage client uses HTTPS. |
| `WORKER_POLL_SECONDS` | No | `30` | How long `training_server.worker` blocks on the Redis queue between checks (durable mode), or sleeps between log lines (placeholder mode). |

## Implemented endpoints

| Method | Endpoint | Auth | Behavior |
|---|---|---:|---|
| `GET` | `/` | No | Lists implemented endpoints. |
| `GET` | `/health` | No | Returns service health. |
| `POST` | `/api/training/upload` | `X-App-Key` | Stores one validated full image, crop image, and class-0 YOLO label. |
| `GET` | `/api/training/stats` | No | Returns upload stats and dataset file counts. |
| `GET` | `/api/training/export` | `X-App-Key` | Returns a ZIP archive of the dataset directory when data exists. |
| `POST` | `/api/training/start` | `X-App-Key` | Starts training (in-process thread, or a queued worker job in durable mode) when at least 10 full images exist. |
| `GET` | `/api/training/status` | No | Returns training state — from an in-memory dict (default) or the `training_runs` table (durable mode); same JSON shape either way. |
| `GET` | `/api/model/version` | No | Returns latest model metadata or `version: none`. |
| `GET` | `/api/model/download` | No | Downloads the latest `.tflite` file or returns 404. |

## Local setup

```bash
cd server
python -m pip install -r requirements.txt
export APP_API_KEY=replace-with-a-long-random-secret
uvicorn main:app --host 0.0.0.0 --port 8000
```

No `DATABASE_URL`/`REDIS_URL`/`OBJECT_STORAGE_*` means filesystem storage and in-process training — no external services required for local development.

## Tests

From the repository root:

```bash
python -m pip install -r server/requirements.txt
APP_API_KEY=test-key ./scripts/test_server.sh
```

The script compiles the server modules, runs `pytest server`, and validates durable-runtime config files. The durable-adapter and queue tests (`test_durable_storage.py`, `test_queue.py`) skip themselves when `DATABASE_URL`/`OBJECT_STORAGE_*`/`REDIS_URL` aren't set, so this needs no services running locally. CI exercises them for real against Postgres/Redis/MinIO service containers (`.github/workflows/server-tests.yml`'s `test-server-durable` job).

## Docker Compose scaffold

From the repository root:

```bash
cp server/.env.example server/.env
# Edit server/.env before production-like use.
docker compose --env-file server/.env up --build
```

The compose stack starts the API, worker, PostgreSQL, Redis, MinIO, and a MinIO bucket initializer, all wired together — `training-api` and `training-worker` both read the durable env vars, so this stack runs on `PostgresMinioStorage` + the Redis job queue, not the filesystem backend. `./scripts/test_compose_integration.sh` boots this exact stack and exercises it end-to-end (upload/stats/export/model-download, plus enqueuing a training job through to the worker claiming it — see that script for why it stops short of waiting on a full YOLO training run).

## Durable storage

**PostgreSQL** (`training_server/durable_storage.py`, tables created idempotently in `initialize()`):
- `training_stats` — single row, upload count and last-upload timestamp.
- `training_samples` — one row per uploaded sample (`sample_id` primary key, label, and the two MinIO object keys).
- `models` — one row per published model (`version` primary key, object key, sha256, size).
- `training_runs` — one row per training run (`queued`/`running`/`success`/`failed`), with a partial unique index enforcing at most one active (`queued` or `running`) run at a time — this is the cross-process replacement for the in-memory lock used in non-durable mode.

**MinIO** object keys: `dataset/images/{sample_id}_full{ext}`, `dataset/images/{sample_id}_crop{ext}`, `models/{version}.tflite`. YOLO labels stay in Postgres (`training_samples.label`), not MinIO — they're one line, not worth a second round trip.

**Redis**: a single list, `training:jobs`. `POST /api/training/start` inserts a `training_runs` row and `LPUSH`es its id; `training_server.worker` blocks on `BRPOP` and processes jobs one at a time. Delivery is at-most-once — a worker crash mid-job leaves that run stuck at `running` with no auto-requeue, which is an accepted tradeoff for a manually-triggered, low-frequency job type.

**Model downloads**: `GET /api/model/download` always serves a local file (`FileResponse`) — `PostgresMinioStorage.latest_model_info()` downloads from MinIO into `models_dir` only on a cache miss (a fresh replica, or a non-compose deployment without the shared `training-models` volume); the common case (worker and API sharing that volume) never triggers a download at all.

## Training notes

- `server/dataset/dataset.yaml` (or, in durable mode, a `materialized_dataset/dataset.yaml` assembled from Postgres/MinIO) is generated at runtime if absent.
- Training requires at least 10 full-image samples.
- The training command uses `yolo detect train` with `yolo11n.pt`.
- Export uses `yolo export format=tflite`.
- The newest published `.tflite` model is served as the current detector model.

## Next steps

1. Add explicit OpenAPI/API-contract documentation if external clients beyond the Flutter app are expected.
