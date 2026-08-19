# DiscFlightSchool

DiscFlightSchool is a monorepo containing a Flutter client and a FastAPI training/model-distribution server for disc golf analysis workflows.

This README reflects an audit of the current repository state on 2026-08-19. It describes only files and behavior that exist in this repository.

## Current repository status

### Flutter client (`disc_golf_app/`)

The Flutter app is the end-user application. Its bootstrap lives in `disc_golf_app/lib/main.dart`, registers app services with Provider, and routes first-time users through onboarding before showing the home screen.

Implemented client areas currently present in source:

- Flight Tracker screens, video playback, overlays, and disc-detection services. Automated detection is track-by-detection: full-frame YOLO discovery locates the disc, then windowed tracking with velocity prediction follows it frame-to-frame (falling back to discovery after a short occlusion streak) instead of re-scanning the whole frame every time. Frames are extracted in a single batched FFmpeg pass rather than one call per frame. A user-seeded keyframe path (`GeometricSplineTracker`/`HybridDiscTracker` behind the `DiscTracker` interface) remains available as a manual/hybrid alternative when automated tracking needs a correction.
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
- The bundled/retrained detector's TFLite output format needs no client-side parsing changes between YOLOv8 and YOLO11: both export the same anchor-free `Detect` head shape (verified against the `ultralytics` source, not assumed). `DiscDetectionService` reads its input tensor size from the loaded model at load time rather than assuming a fixed resolution.

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
| `POST` | `/api/training/start` | `X-App-Key` | Starts a background YOLO11 (`yolo11n.pt`) training/export thread if at least 10 full images exist. |
| `GET` | `/api/training/status` | No | Returns training status (in-memory, or from PostgreSQL in durable mode — same JSON shape either way). |
| `GET` | `/api/model/version` | No | Returns latest `.tflite` model metadata or the no-model sentinel. |
| `GET` | `/api/model/download` | No | Downloads the latest `.tflite` model or returns 404 when none exists. |

Important server facts:

- `APP_API_KEY` is required to start the server.
- Storage backend is selected automatically: `PostgresMinioStorage` (durable) when `DATABASE_URL`, `REDIS_URL`, and every `OBJECT_STORAGE_*` variable are set, otherwise `FileStorage` (filesystem, local dev, no infra required).
- In durable mode, `POST /api/training/start` enqueues a job on a Redis list instead of spawning an in-process thread; `training_server.worker` consumes it, runs the same `yolo detect train`/`yolo export` sequence, and publishes the resulting model through the storage layer. Without durable config, `training_server.worker` falls back to its original placeholder behavior (log config booleans and sleep).
- `server/dataset/dataset.yaml` (or, in durable mode, a materialized copy assembled from Postgres/MinIO) is generated at runtime if it is absent.
- See `server/README.md`'s "Durable storage" section for the Postgres schema and MinIO object-key layout.

### Docker Compose runtime scaffold

The root `docker-compose.yml` defines services for:

- `training-api`
- `training-worker`
- `postgres`
- `redis`
- `minio`
- `minio-init`

`training-api` and `training-worker` both run with the durable env vars set, so this stack exercises `PostgresMinioStorage` and the Redis training queue, not the filesystem backend. `./scripts/test_compose_integration.sh` boots this stack and exercises it end-to-end (see `.github/workflows/compose-integration.yml`, which runs it on push to `main`).

## Project layout

```text
DiscFlightSchool/
├── .github/workflows/          # GitHub Actions for Flutter build/tests and server tests
├── disc_golf_app/              # Flutter application
│   ├── android/                # Android Gradle project
│   ├── assets/                 # JSON, images, studies, and bundled TFLite model
│   ├── lib/                    # Dart app code
│   └── test/                   # Flutter unit, widget, and data-contract tests
├── docs/                       # testing.md, dependency-audit-troubleshooting.md,
│                               #   and the Google Play readiness report/plan
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
neither was called by anything, and both have been removed. A further sweep on
2026-08-19 removed a second layer of dead code that had accumulated behind
that same never-routed Flight Analysis screen: `flight_analysis_screen.dart`,
`flight_data_service.dart`, the `output_coordinates.json`/`analysis_results.json`
assets it read, the unused `flight_data.dart`/`disc.dart` models, the unused
`AppConstants`/`Helpers` utility classes, an unused `VideoControls` widget, a
second (unused) `FlightPathPainter` in `flight_path_overlay.dart` shadowing the
one actually in use, and two never-routed screens (`manual_tracking_screen.dart`,
`game_session_screen.dart`). None of it was imported from anywhere reachable —
`flutter analyze`/`flutter test` were re-run clean after removal. Recover any
of it from git history if you want to revive that path.

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

1. **TODO: verify the YOLO11 track-by-detection pipeline on a real device with a real
   throw video.** The detector upgrade (`yolo11n.pt`), the FFmpeg batch frame
   extraction, the GPU delegate, and the discovery/tracking/occlusion state
   machine are covered by `flutter analyze`/`flutter test` at the pure-function
   level only — none of that is exercised against a real video or a real TFLite
   interpreter yet. See `docs/testing.md` for the specific checklist.
2. Keep docs synchronized with source whenever endpoints, assets, build settings, or runtime services change.
3. Move disc detection off the UI isolate — see `docs/testing.md` for what is
   still unverified and why.

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
