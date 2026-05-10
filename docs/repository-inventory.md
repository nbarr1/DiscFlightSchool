# Repository Inventory

Audited on 2026-05-10.

## Top-level files/directories

- `.github/workflows/`: GitHub Actions workflows for Flutter build/tests and server tests.
- `.vscode/`: editor launch configuration.
- `README.md`: repository overview and build instructions.
- `disc_golf_app/`: Flutter client project.
- `docker-compose.yml`: API/worker/Postgres/Redis/MinIO scaffold.
- `docs/`: audit, status, and planning docs.
- `scripts/`: local test/validation scripts.
- `server/`: FastAPI training/model server.

## Flutter client inventory

Important source areas under `disc_golf_app/lib/`:

- `main.dart`: app bootstrap, providers, theme, startup router.
- `models/`: disc, flight data, form analysis, form session, knowledge base, roulette, detector model, and training sample models.
- `services/`: tracking, video, posture analysis, scoring, disc detection, hybrid detection, form history, roulette history, knowledge base, feedback, training data, and Python bridge services.
- `screens/`: home, onboarding, flight tracker, form coach, roulette, knowledge base, settings, gallery, and flight analysis screens.
- `widgets/`: flight path, follow-flight, roulette wheel, skeleton overlay, and video controls.
- `utils/`: angle calculation, constants, helpers, and pro-data parsing.
- `data/repositories/`: repository interface definitions for future persistence migration.

Client assets include:

- Bundled JSON data in `assets/data/`.
- Bundled TFLite model in `assets/models/disc_detector.tflite`.
- Basket SVG in `assets/images/`.
- Study PDFs and extracted text in `assets/Studies/`.
- Platform icons/images for Android, iOS, macOS, web, and Windows.

Client tests:

- `test/widget_test.dart`.
- `test/data_contracts_test.dart`.

## Server inventory

Important files under `server/`:

- `main.py`: app entrypoint and compatibility helpers.
- `training_server/app.py`: FastAPI routes and middleware.
- `training_server/config.py`: environment-backed settings.
- `training_server/storage.py`: filesystem storage adapter.
- `training_server/training.py`: in-process background YOLO training/export orchestration.
- `training_server/validation.py`: validation helpers.
- `training_server/protocols.py`: storage protocol/typed dicts.
- `training_server/worker.py`: placeholder worker loop.
- `test_config.py`, `test_http_contracts.py`, `test_storage.py`, `test_validation.py`: server tests.
- `Dockerfile`, `Procfile`, `.env.example`, `.dockerignore`, `requirements.txt`: deployment/runtime files.

## Scripts and workflows

- `scripts/test_server.sh`: compiles server modules, runs server tests, validates durable runtime files.
- `scripts/test_flutter.sh`: runs Flutter pub get, analyzer, and tests.
- `scripts/validate_durable_runtime.py`: static validation for compose/env scaffold.
- `.github/workflows/server-tests.yml`: Python server test workflow.
- `.github/workflows/flutter-tests.yml`: Flutter test workflow.
- `.github/workflows/build.yml`: Flutter build workflow with analyzer/tests before APK build.

## Generated/ignored runtime files

The server can generate runtime files that should not be treated as committed source unless intentionally added:

- `server/dataset/dataset.yaml`.
- `server/stats.json`.
- `server/exports/`.
- `server/runs/`.
- New trained `.tflite` files under `server/models/`.
