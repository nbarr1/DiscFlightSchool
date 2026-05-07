# Disc Flight School Training Server

This is the Phase 4 rebuilt server entrypoint for Disc Flight School training data collection and model distribution. The public HTTP contract remains compatible with the original `server/main.py` routes while the implementation is split into explicit configuration, validation, storage, app-factory, and training orchestration modules.

## What it does

- Accepts authenticated disc-detection training samples as multipart uploads.
- Stores full images, crop images, and YOLO class-0 labels in the dataset directory.
- Reports dataset stats.
- Exports the YOLO dataset as a ZIP archive.
- Serves the latest `.tflite` detector model and SHA-256 metadata.
- Starts YOLOv8 training in a background thread when enough samples exist.
- Exposes `/health` and `/api/training/status` for operations.

## Configuration

| Variable | Required | Default | Description |
|---|---:|---|---|
| `APP_API_KEY` | Yes | none | Shared private key required by upload/export/training-start endpoints. |
| `CORS_ALLOW_ORIGINS` | No | empty | Comma-separated list of allowed browser origins. |
| `MAX_UPLOAD_BYTES` | No | `8388608` | Maximum bytes per uploaded image. |
| `TRAINING_TIMEOUT_SECONDS` | No | `7200` | Timeout for the YOLO training subprocess. |
| `MODEL_EXPORT_TIMEOUT_SECONDS` | No | `600` | Timeout for the YOLO TFLite export subprocess. |
| `TRAINING_EPOCHS` | No | `50` | Epoch count passed to `yolo detect train`. |
| `TRAINING_IMAGE_SIZE` | No | `640` | Image size passed to YOLO train/export commands. |
| `TRAINING_BATCH_SIZE` | No | `16` | Batch size passed to `yolo detect train`. |

## Run locally

```bash
cd server
python -m pip install -r requirements.txt
export APP_API_KEY=replace-with-a-long-random-secret
uvicorn main:app --host 0.0.0.0 --port 8000
```

## Run tests

```bash
cd server
APP_API_KEY=test-key ../scripts/test_server.sh
```

## Deploy

The existing Dockerfile and Procfile still run `main:app`. Set `APP_API_KEY` and any optional environment variables in the target platform secret/config system before starting the container.
