# Disc Flight School Training Server

This directory contains the FastAPI training/model-distribution server for DiscFlightSchool. This README reflects the current source tree as audited on 2026-05-10.

## Runtime shape

- `main.py` is the deployment entrypoint and creates `app` from `training_server.create_app()`.
- `training_server/config.py` loads required and optional environment variables.
- `training_server/app.py` defines the HTTP routes.
- `training_server/storage.py` implements the current filesystem-backed storage adapter.
- `training_server/training.py` starts YOLOv8 training/export in a background thread.
- `training_server/validation.py` validates sample IDs, YOLO labels, file extensions, signatures, and safe child paths.
- `training_server/worker.py` is a placeholder worker that validates configuration and sleeps; it does not process queue jobs yet.

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
| `DATABASE_URL` | No | none | Parsed for future durable runtime work; no database adapter uses it yet. |
| `REDIS_URL` | No | none | Parsed for future queue work; no Redis queue adapter uses it yet. |
| `OBJECT_STORAGE_ENDPOINT` | No | none | Parsed for future object-storage work; no object-storage adapter uses it yet. |
| `OBJECT_STORAGE_BUCKET` | No | none | Parsed for future object-storage work. |
| `OBJECT_STORAGE_ACCESS_KEY` | No | none | Parsed for future object-storage work. |
| `OBJECT_STORAGE_SECRET_KEY` | No | none | Parsed for future object-storage work. |
| `OBJECT_STORAGE_SECURE` | No | `true` | Parsed as a boolean for future object-storage work. |

## Implemented endpoints

| Method | Endpoint | Auth | Behavior |
|---|---|---:|---|
| `GET` | `/` | No | Lists implemented endpoints. |
| `GET` | `/health` | No | Returns service health. |
| `POST` | `/api/training/upload` | `X-App-Key` | Stores one validated full image, crop image, and class-0 YOLO label. |
| `GET` | `/api/training/stats` | No | Returns upload stats and dataset file counts. |
| `GET` | `/api/training/export` | `X-App-Key` | Returns a ZIP archive of the dataset directory when data exists. |
| `POST` | `/api/training/start` | `X-App-Key` | Starts background training when at least 10 full images exist. |
| `GET` | `/api/training/status` | No | Returns in-memory training state. |
| `GET` | `/api/model/version` | No | Returns latest model metadata or `version: none`. |
| `GET` | `/api/model/download` | No | Downloads the latest `.tflite` file or returns 404. |

## Local setup

```bash
cd server
python -m pip install -r requirements.txt
export APP_API_KEY=replace-with-a-long-random-secret
uvicorn main:app --host 0.0.0.0 --port 8000
```

## Tests

From the repository root:

```bash
python -m pip install -r server/requirements.txt
APP_API_KEY=test-key ./scripts/test_server.sh
```

The script compiles the server modules, runs `pytest server`, and validates durable-runtime config files.

## Docker Compose scaffold

From the repository root:

```bash
cp server/.env.example server/.env
# Edit server/.env before production-like use.
docker compose --env-file server/.env up --build
```

The compose stack starts the API, placeholder worker, PostgreSQL, Redis, MinIO, and a MinIO bucket initializer. Filesystem storage remains the implemented API storage backend; PostgreSQL, Redis, and MinIO are not used by current request handlers.

## Training notes

- `server/dataset/dataset.yaml` is generated at runtime if absent.
- Training requires at least 10 full-image samples on disk.
- The training command uses `yolo detect train` with `yolov8n.pt`.
- Export uses `yolo export format=tflite`.
- The newest `.tflite` file under `server/models/` is served as the current detector model.

## Next steps

1. Add durable database/object-storage/queue adapters before depending on PostgreSQL, Redis, or MinIO for live server state.
2. Add integration tests around upload/export/model-download behavior using the Docker Compose stack.
3. Add explicit OpenAPI/API-contract documentation if external clients beyond the Flutter app are expected.
4. Decide whether training should remain in-process background work or move to the worker once Redis queueing is implemented.
