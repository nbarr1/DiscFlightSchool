# DiscFlightSchool

DiscFlightSchool is a monorepo containing a Flutter client and a FastAPI training/model-distribution server for disc golf analysis workflows.

This README reflects an audit of the current repository state on 2026-05-10. It describes only files and behavior that exist in this repository.

## Current repository status

### Flutter client (`disc_golf_app/`)

The Flutter app is the end-user application. Its bootstrap lives in `disc_golf_app/lib/main.dart`, registers app services with Provider, and routes first-time users through onboarding before showing the home screen.

Implemented client areas currently present in source:

- Flight Tracker screens, manual tracking, video playback, overlays, and disc-detection services.
- Form Coach screens for video trimming, posture analysis, phase selection/comparison, pose correction, and session history.
- Disc Roulette screens, scoring models, scoring service, and roulette history service.
- Knowledge Base screens and local JSON-backed content models/services.
- Training Settings for opt-in sample collection, server URL/API-key configuration, pending upload management, and detector model update checks.
- Repository interface foundations under `disc_golf_app/lib/data/repositories/`; these are interfaces only and are not yet wired as concrete persistence adapters for the existing UI flows.

Important client facts:

- Package name: `disc_golf_app`.
- Published version in `pubspec.yaml`: `1.0.0+1`.
- Dart SDK constraint: `>=3.8.0 <4.0.0`.
- Android application ID: `com.discflightschool.app`.
- Android compile SDK: `36`.
- Android NDK version requested by Gradle: `27.0.12077973`.
- Release builds use a `key.properties` signing config when present; otherwise the release build type falls back to the debug signing config.
- Bundled runtime assets include JSON data files, `assets/models/disc_detector.tflite`, an SVG basket image, and Flutter material assets.

### Training server (`server/`)

The server is a FastAPI app. `server/main.py` is the deployment entrypoint and delegates to the `training_server` package.

Implemented server endpoints:

| Method | Endpoint | Auth | Current behavior |
|---|---|---:|---|
| `GET` | `/` | No | Lists implemented endpoints. |
| `GET` | `/health` | No | Returns `{"status":"ok"}`. |
| `POST` | `/api/training/upload` | `X-App-Key` | Validates sample ID, YOLO class-0 label, positive dimensions, JPEG/PNG signatures, and stores full image, crop image, and label on disk. |
| `GET` | `/api/training/stats` | No | Returns stored stats and on-disk image/label counts. |
| `GET` | `/api/training/export` | `X-App-Key` | Builds and returns a ZIP of the dataset directory when data exists. |
| `POST` | `/api/training/start` | `X-App-Key` | Starts a background YOLOv8 training/export thread if at least 10 full images exist. |
| `GET` | `/api/training/status` | No | Returns in-memory training status. |
| `GET` | `/api/model/version` | No | Returns latest `.tflite` model metadata or the no-model sentinel. |
| `GET` | `/api/model/download` | No | Downloads the latest `.tflite` model or returns 404 when none exists. |

Important server facts:

- `APP_API_KEY` is required to start the server.
- Filesystem storage is the only implemented storage backend.
- Optional database, Redis, and object-storage settings are parsed, but no PostgreSQL, Redis queue, or object-storage adapter is implemented yet.
- `training_server.worker` is a placeholder process that validates configuration and sleeps; it does not consume jobs.
- `server/dataset/dataset.yaml` is generated at runtime by `FileStorage.initialize()` if it is absent.

### Docker Compose runtime scaffold

The root `docker-compose.yml` defines services for:

- `training-api`
- `training-worker`
- `postgres`
- `redis`
- `minio`
- `minio-init`

The compose stack is a scaffold for remote/local validation. The API and worker currently still use filesystem-backed training data/model/export volumes. PostgreSQL, Redis, and MinIO are provisioned but not yet used by implemented adapters.

## Project layout

```text
DiscFlightSchool/
├── .github/workflows/          # GitHub Actions for Flutter build/tests and server tests
├── disc_golf_app/              # Flutter application
│   ├── android/                # Android Gradle project
│   ├── assets/                 # JSON, images, studies, and bundled TFLite model
│   ├── lib/                    # Dart app code
│   ├── python/                 # Prototype Flask/Python analysis helpers, not embedded by Flutter
│   └── test/                   # Flutter widget and data-contract tests
├── docs/                       # Current audit/status/planning documents
├── scripts/                    # Local test and validation scripts
├── server/                     # FastAPI training/model server
│   ├── training_server/        # App factory, config, storage, training, validation, worker
│   └── test_*.py               # Server tests
└── docker-compose.yml          # API/worker/Postgres/Redis/MinIO scaffold
```

## Local development

### Server checks

```bash
python -m pip install -r server/requirements.txt
APP_API_KEY=test-key ./scripts/test_server.sh
```

### Flutter checks

```bash
./scripts/test_flutter.sh
```

The Flutter script requires `flutter` on `PATH` and runs `flutter pub get`, `flutter analyze`, and `flutter test` inside `disc_golf_app/`.

## Building a testable Android APK

A testable Android APK is currently built from the Flutter project, not from the server.

Prerequisites:

1. Flutter SDK compatible with Dart `>=3.8.0 <4.0.0`.
2. Android SDK with compile SDK 36 installed.
3. Android NDK `27.0.12077973` installed or installable by the Android tooling.
4. Java 17 available to Gradle/Android tooling.
5. Network access for first-time dependency resolution unless dependencies are already cached.

Recommended validation/build sequence:

```bash
cd disc_golf_app
flutter doctor -v
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Expected debug APK output:

```text
disc_golf_app/build/app/outputs/flutter-apk/app-debug.apk
```

For a signed release APK, add `disc_golf_app/android/key.properties` with `keyAlias`, `keyPassword`, `storeFile`, and `storePassword`, then run:

```bash
cd disc_golf_app
flutter build apk --release
```

Without `key.properties`, the current Gradle configuration falls back to debug signing for the release build type, which can be useful for local testing but is not suitable for store distribution.

## Current next steps

1. Keep docs synchronized with source whenever endpoints, assets, build settings, or runtime services change.
2. Add concrete repository implementations for the Flutter repository interfaces, then migrate services/screens behind those interfaces with tests.
3. Add server durable adapters before claiming PostgreSQL, Redis, or MinIO persistence is implemented.
4. Add integration tests for Docker Compose once durable adapters exist.
5. Add Android build validation to CI if an APK artifact is required from every merge.
