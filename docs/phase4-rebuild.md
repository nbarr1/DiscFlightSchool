# Phase 4 Rebuild — Server Foundation

Phase 4 begins with a production-oriented rebuild of the training/model server while preserving the observable HTTP contracts documented in Phase 2. The Flutter client remains unchanged in this step; this keeps the first rebuild slice small enough to validate through automated contract tests before moving to the larger client rewrite.

## Implemented Scope

- Replaced the monolithic `server/main.py` implementation with a thin compatibility entrypoint.
- Added `server/training_server/config.py` for environment-backed runtime configuration.
- Added `server/training_server/validation.py` for sample id, YOLO label, safe path, extension, and image signature validation.
- Added `server/training_server/storage.py` for filesystem-backed dataset, stats, export, and model artifact operations.
- Added `server/training_server/training.py` for thread-backed YOLO training orchestration.
- Added `server/training_server/app.py` as an explicit FastAPI app factory with injected settings/storage/trainer dependencies.
- Preserved legacy helper names in `server/main.py` so existing validation tests and operational snippets continue to work.
- Added ASGI-level HTTP contract tests that do not require `httpx` or network access.
- Added server README documentation for configuration, local run, tests, and deployment.

## Preserved Behavior

- `APP_API_KEY` is still required before importing/running `main:app`.
- Mutating endpoints still authenticate with `X-App-Key`.
- Uploads still accept `sample_id`, `label`, `image_width`, `image_height`, optional `app_version`, `full_image`, and `crop_image`.
- Upload validation still enforces safe sample ids, single-row class-0 normalized YOLO labels, positive image dimensions, image magic bytes, and max upload size.
- Dataset files still use the original YOLO directory layout under `dataset/images/train` and `dataset/labels/train`.
- Model version/download, stats, export, training start/status, health, and root metadata routes keep their original paths and response shapes.
- YOLO training still shells out to the `yolo` CLI and exports `.tflite` artifacts into `server/models`.

## Deliberate Differences

- Code is split by responsibility instead of keeping configuration, validation, storage, endpoints, and training in one file.
- The app can now be constructed with test-specific `Settings`, which enables isolated temp-directory contract tests.
- Backwards-compatible helper functions in `main.py` delegate to the new modules instead of owning the business logic.
- HTTP contract tests exercise the FastAPI ASGI app directly with handcrafted multipart payloads to avoid adding a new test-only dependency.

## Migration Plan

No persistent schema migration is required for this server slice. Existing local server state remains valid:

1. Keep `server/dataset/images/train`, `server/dataset/labels/train`, `server/models`, and `server/stats.json` in place.
2. Deploy the rebuilt server with the same `APP_API_KEY`, `CORS_ALLOW_ORIGINS`, and `MAX_UPLOAD_BYTES` values.
3. Start the server; `FileStorage.initialize()` recreates missing directories and `dataset.yaml` when needed.
4. Validate `/health`, `/api/training/stats`, `/api/model/version`, and one authenticated upload against the target environment.
5. Trigger `/api/training/export` and compare label/image counts against the previous deployment before enabling new training runs.

## Remote Progress

- Added a dedicated server CI gate and reusable local test script as the first remote-verifiable Phase 4 follow-up.
- Added request-id propagation and structured request lifecycle logging as the second remote-verifiable Phase 4 follow-up.
- Added validated remote training configuration knobs and tests as the third remote-verifiable Phase 4 follow-up.
- Hardened upload/export concurrency by moving blocking handlers to FastAPI's thread pool and generating unique temporary export ZIP files.
- Added the storage backend protocol boundary and verified the filesystem adapter against it as the fourth remote-verifiable Phase 4 follow-up.
- Started the Flutter data-layer foundation with repository contracts, shared models, and a migration plan.
- Added remote Flutter analyze/test CI and a reusable local Flutter test script before APK builds.

## Remaining Phase 4 Work

- Finish the Flutter client architecture around Riverpod, Drift implementations, and generated API clients.
- Add local SQLite migrations from SharedPreferences/JSON storage.
- Add durable PostgreSQL/object-storage/queue adapters for the server when the deployment environment is ready.
- Add OpenTelemetry logging/metrics/tracing and request-id propagation.
- Add model-update and upload integration tests that run against a live ASGI server/container.
