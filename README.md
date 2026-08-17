# DiscFlightSchool

DiscFlightSchool is a monorepo containing a Flutter client and a FastAPI training/model-distribution server for disc golf analysis workflows.

This README reflects an audit of the current repository state on 2026-08-04. It describes only files and behavior that exist in this repository.

## Current repository status

### Flutter client (`disc_golf_app/`)

The Flutter app is the end-user application. Its bootstrap lives in `disc_golf_app/lib/main.dart`, registers app services with Provider, and routes first-time users through onboarding before showing the home screen.

Implemented client areas currently present in source:

- Flight Tracker screens, manual tracking, video playback, overlays, and disc-detection services.
- Form Coach screens for video trimming, posture analysis, phase selection/comparison, pose correction, and session history.
- Disc Roulette screens, scoring models, scoring service, and roulette history service.
- Knowledge Base screens and local JSON-backed content models/services.
- Training Settings for opt-in sample collection, server URL/API-key configuration, pending upload management, and detector model update checks.

There is no repository/persistence abstraction layer; services own their own
storage (SharedPreferences, secure storage, or the app documents directory).

Important client facts:

- Package name: `disc_golf_app`.
- Published version in `pubspec.yaml`: `1.0.0+1`.
- Dart SDK constraint: `>=3.8.0 <4.0.0`.
- Android application ID: `com.discflightschool.app`.
- Android compile SDK: `36`.
- Android NDK version requested by Gradle: `27.0.12077973`.
- Release builds require a complete `key.properties` signing config; unsigned local testing should use debug builds.
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
│   └── test/                   # Flutter unit, widget, and data-contract tests
├── docs/                       # Current audit/status/planning documents
├── scripts/                    # Local test and validation scripts
├── server/                     # FastAPI training/model server
│   ├── training_server/        # App factory, config, storage, training, validation, worker
│   ├── requirements.txt        # Production runtime pins
│   ├── requirements-test.txt   # Test env pins (must agree; enforced by test_requirements.py)
│   └── test_*.py               # Server tests
└── docker-compose.yml          # API/worker/Postgres/Redis/MinIO scaffold
```

There is no Python code in the Flutter app. A prototype Flask service formerly
lived at `disc_golf_app/python/`, reachable through `python_bridge_service.dart`;
neither was called by anything, and both have been removed. The Flight Analysis
screen reads `assets/data/output_coordinates.json` and
`assets/data/analysis_results.json` bundled with the app — it never called that
service. Recover either from git history if you want to revive that path.

## Local development

### Server checks

```bash
# requirements-test.txt omits ultralytics (torch) but pins every shared
# dependency identically to requirements.txt; test_requirements.py fails the
# build if the two ever drift.
python -m pip install -r server/requirements-test.txt
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

Without `key.properties`, release builds now fail fast; use `flutter build apk --debug` for local unsigned testing.

### Bumping the app version for a release

`disc_golf_app/pubspec.yaml`'s `version:` field (`versionName+versionCode`, e.g. `1.0.0+1`) is the single source for both the Android `versionCode`/`versionName` and the iOS `CFBundleVersion`/`CFBundleShortVersionString` — Gradle and Xcode both read it via Flutter's build tooling, nothing else needs editing. **Increment the `+N` build-number suffix on every release submitted to an app store**, even for a patch that only touches `versionName` (e.g. `1.0.0+1` → `1.0.1+2`): Google Play and the App Store both reject a re-upload whose build number doesn't strictly increase over the previous release.

## Current next steps

1. Keep docs synchronized with source whenever endpoints, assets, build settings, or runtime services change.
2. Move disc detection off the UI isolate — see `docs/testing.md` for what is
   still unverified and why.
3. Add server durable adapters before claiming PostgreSQL, Redis, or MinIO persistence is implemented.
4. Add integration tests for Docker Compose once durable adapters exist.
5. Add Android build validation to CI if an APK artifact is required from every merge.

## Running the compose stack

`docker-compose.yml` reads `server/.env.example` for non-secret defaults but
requires every credential to be supplied by your shell, so the committed
placeholders can never become live credentials:

```bash
export APP_API_KEY="$(python -c 'import secrets; print(secrets.token_urlsafe(32))')"
export POSTGRES_DB=discflight POSTGRES_USER=discflight
export POSTGRES_PASSWORD='...' MINIO_ROOT_USER='...' MINIO_ROOT_PASSWORD='...'
docker compose up
```
