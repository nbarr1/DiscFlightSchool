# Phase 1 Repository Audit — DiscFlightSchool

This document is the Phase 1 reconnaissance record for the repository. It intentionally stops before Phase 2 synthesis/rebuild work because the requested workflow says not to proceed beyond Phase 1 until the audit is exhaustive.

## Audit Method

- Confirmed repository root: `/workspace/DiscFlightSchool`.
- Searched for `AGENTS.md`; none were present in `/workspace` or shallow filesystem locations, so no repository-local agent instructions apply.
- Enumerated the source tree without recursive `ls`; generated the canonical artifact list in [`docs/repository-inventory.md`](repository-inventory.md).
- Read all UTF-8 text artifacts outside `.git`, Android `build/`, and Android `.gradle`; binary artifacts were inventoried by path and role.
- Inspected Flutter/Dart entry points, models, services, screens, widgets, native platform shells, Python helper modules, FastAPI server, manifests, lock files, tests, assets, deployment descriptors, and CI workflow.

## 1. Structure Mapping

### Project Type

DiscFlightSchool is a mobile-first monorepo-style product with two runnable layers:

1. `disc_golf_app/`: a Flutter application targeting Android, iOS, web, macOS, Linux, and Windows. It is the primary end-user product and includes most business logic locally.
2. `server/`: a FastAPI training/model-distribution service that receives opt-in disc-detection training samples, exports a YOLO dataset, launches training, and serves the latest TFLite model.

A third, legacy/prototype Python layer lives under `disc_golf_app/python/`. The Flutter app does not embed Python directly; `PythonBridgeService` talks to an HTTP endpoint, while the Python files provide a Flask prototype for disc detection and posture comparison.

### Directory Boundaries

- Root documentation/configuration: `README.md`, `.github/workflows/build.yml`, `.vscode/launch.json`, `.claude/settings.local.json`.
- Flutter app: `disc_golf_app/`.
  - `lib/main.dart`: app bootstrap, providers, theme, startup routing.
  - `lib/models/`: persisted and in-memory domain/data contracts.
  - `lib/services/`: stateful application services, local persistence, analysis, upload, model update, scoring, and external API calls.
  - `lib/screens/`: feature screens grouped by Form Coach, Flight Tracker, Knowledge Base, Roulette, settings, onboarding, gallery.
  - `lib/widgets/`: reusable painters and controls.
  - `lib/utils/`: geometric calculations, constants, baseline parsing, helper utilities.
  - `assets/data/`: bundled baseline, knowledge-base, flight-path, and sample-analysis JSON.
  - `assets/Studies/`: research PDFs and extracted text used by the knowledge base.
  - `assets/models/`: bundled `disc_detector.tflite`.
  - Native shells: `android/`, `ios/`, `macos/`, `linux/`, `windows/`, `web/`.
  - `test/widget_test.dart`: default Flutter widget smoke test.
- Server: `server/`.
  - `main.py`: FastAPI server and all endpoints.
  - `requirements.txt`: Python server runtime dependencies.
  - `Dockerfile`, `Procfile`: container/Heroku-style deployment descriptors.
  - `test_validation.py`: lightweight validation unit checks.
  - `dataset/images/train`, `dataset/labels/train`: YOLO dataset roots with `.gitkeep` placeholders.
  - `models/disc_detector.tflite`: latest model artifact.

### Entry Points

- Flutter UI: `disc_golf_app/lib/main.dart`, `void main() => runApp(const DiscGolfApp())`.
- Flutter startup route: `_StartupRouter`, which reads SharedPreferences key `onboarding_complete` to choose `OnboardingScreen` or `HomeScreen`.
- Android entry: `android/app/src/main/kotlin/com/discflightschool/app/MainActivity.kt`.
- iOS entry: `ios/Runner/AppDelegate.swift`.
- macOS entry: `macos/Runner/AppDelegate.swift` / `MainFlutterWindow.swift`.
- Linux entry: `linux/runner/main.cc`.
- Windows entry: `windows/runner/main.cpp`.
- Web entry: `web/index.html` + generated Flutter loader path.
- Training server: `server/main.py`, runnable via `uvicorn main:app`.
- Prototype Flask API: `disc_golf_app/python/api/server.py`, runnable as a local Flask process.

## 2. Dependency Audit

### Flutter Runtime

- Dart SDK constraint: `>=3.8.0 <4.0.0`.
- Flutter: UI toolkit and platform integration.
- `provider`: app-wide `ChangeNotifier` dependency injection/state management.
- `shared_preferences`: local primitive persistence for onboarding, service state, history, thresholds, scored rounds, and settings.
- `flutter_secure_storage`: secure local storage for training-server and Anthropic API keys.
- `video_player`, `video_thumbnail`, `ffmpeg_kit_flutter_new`: video playback, thumbnail/frame extraction, and video processing/trimming.
- `image_picker`, `file_picker`, `gal`, `share_plus`: media import/export, gallery save, and sharing.
- `google_mlkit_pose_detection`: on-device pose landmark detection for Form Coach.
- `tflite_flutter`, `image`: on-device disc detector inference and image preprocessing.
- `http`: calls to training server, local Python bridge, and Anthropic API.
- `archive`: ZIP/archive support for downloaded model/data workflows.
- `crypto`: SHA-256 verification of downloaded TFLite models.
- `flutter_svg`, `cupertino_icons`: UI assets/icons.
- Dev dependencies: `flutter_test` and `flutter_lints`.

### Server Runtime

- Python 3.11 image in `server/Dockerfile`; Python package constraints in `server/requirements.txt`.
- `fastapi`: HTTP API, request parsing, multipart forms, OpenAPI generation.
- `uvicorn`: ASGI development/runtime server.
- `gunicorn`: production process manager.
- `python-multipart`: multipart upload parsing required for FastAPI file/form endpoints.
- `ultralytics`: YOLOv8 training/export used by `/api/training/start`.

### Prototype Python Runtime

- `flask` and `flask-cors`: local HTTP bridge server.
- `opencv-python-headless`: video/image frame handling and simple detection heuristics.
- `numpy`: trajectory and posture numeric operations.
- `mediapipe`: prototype pose landmark detection.
- `pillow`: image manipulation dependency.

### Transitive Dependencies

`pubspec.lock` and Python package managers resolve many transitive packages. No code imports those directly except through the direct packages above. Operationally important transitive areas include native ML/video binaries, platform storage APIs, and HTTP/security primitives brought by Flutter plugins.

## 3. Interface Inventory

### FastAPI HTTP API

All authenticated server endpoints use the `X-App-Key` header and compare it to `APP_API_KEY`. Missing or invalid keys return HTTP `403` with `{"error":"Invalid or missing API key"}`.

| Method | Path | Auth | Contract | Failure Modes |
|---|---|---|---|---|
| `POST` | `/api/training/upload` | `X-App-Key` | Multipart form: `sample_id`, `label`, `image_width`, `image_height`, optional `app_version`, files `full_image`, `crop_image`. Stores YOLO sample and returns `{"status":"ok","sample_id", "message":"Sample received"}`. | `403` auth, `400` invalid sample id, invalid label, non-positive dimensions, too-large upload, bad JPEG/PNG signature. |
| `GET` | `/api/model/version` | none | Returns `version`, `sha256`, `url`; if no model: `version:"none"`, empty hash/url. | None expected. |
| `GET` | `/api/model/download` | none | File download of latest `.tflite`. | `404 {"error":"No model available"}`. |
| `GET` | `/api/training/stats` | none | Returns stats plus current image count and label count. | None expected. |
| `GET` | `/api/training/export` | `X-App-Key` | Generates and downloads `training_data_export.zip` with images, labels, and dataset YAML. | `403` auth. |
| `POST` | `/api/training/start` | `X-App-Key` | Starts background YOLOv8 training if at least 10 full images exist; returns started status. | `403` auth, `409` already running, `400` insufficient data. |
| `GET` | `/api/training/status` | none | Returns in-memory training status: `running`, `last_run`, `result`. | None expected. |
| `GET` | `/health` | none | Returns `{"status":"ok"}`. | None expected. |
| `GET` | `/` | none | Service metadata and endpoint list. | None expected. |

### Flutter App Interfaces

- User navigation is direct Flutter routing (`Navigator.push`/`MaterialPageRoute`) instead of URL/deep-link routing.
- Local service contracts are exposed through `ChangeNotifier` services injected with `Provider`.
- Training uploads are made by `TrainingDataService` to `/api/training/upload`; model version/download checks are made from Training Settings.
- Optional AI Knowledge Base Q&A uses Anthropic's HTTP Messages API from `KnowledgeBaseService` / AI search screen; the API key is user-provided and stored in secure storage.
- Optional Python analysis bridge uses HTTP calls to a configured or default local Flask endpoint; it is a prototype/non-primary integration.

### CLI / Build Interfaces

- Flutter: `flutter pub get`, `flutter run`, `flutter test`, `flutter build <platform>`.
- Server: `uvicorn main:app --host 0.0.0.0 --port 8000`, `gunicorn`/`uvicorn.workers.UvicornWorker` via Procfile, or Dockerfile.
- Training pipeline invocation: `python scripts/sync_to_app.py --all --server ...` is documented as belonging to a separate repository, not this repo.

## 4. Data Model Extraction

### Persistent Local Flutter Models

- `TrainingSample`: `id`, `imagePath`, `cropPath`, normalized YOLO coordinates (`centerX`, `centerY`, `boxWidth`, `boxHeight`), frame/image dimensions, `createdAt`, `uploaded`. Converts to YOLO label string class `0`.
- `Disc`: disc catalog entry with name, manufacturer, type, flight numbers, optional image URL.
- `FlightData`: recorded flight metrics (`distance`, `maxHeight`, `flightTime`, `speed`, `launchAngle`), 2D point list, optional video/disc ids, timestamp.
- `FormFrame`: timestamp, angle map, 2D keypoints, depth/confidence maps, optional image dimensions.
- `FormAnalysis`: session id/date/video path, frame list, score.
- `ProFormData`: player name, `FormAnalysis`, description.
- `FormSessionRecord`: saved history summary: id/date/score/throw type/pro player/frame count/average angles.
- `KBStudy`, `KBArticle`, `KBCategory`: knowledge-base content loaded from bundled JSON.
- `RouletteResult`, `GameSession`, `ThrowRecord`, `HoleScore`, `ScoredRound`: Disc Roulette challenges, sessions, hole scores, weighted scores, round state.

### Bundled JSON Assets

- `assets/data/pro_baseline_db.json`: metadata, five players, BH/FH phase data, baseline summaries, quality flags. Used for Form Coach pro comparison.
- `assets/data/knowledge_base.json`: categories, studies, and articles. Used for in-app browsing and linked coaching suggestions.
- `assets/data/output_coordinates.json`: sample flight path coordinates plus video metadata.
- `assets/data/analysis_results.json`: sample/pro angle comparison values.

### Server Stored Shapes

- `server/dataset/images/train/{sample_id}_full.{jpg|jpeg|png}` and `{sample_id}_crop.{jpg|jpeg|png}`.
- `server/dataset/labels/train/{sample_id}.txt`: one YOLO row: `0 center_x center_y width height`; all values normalized to `[0,1]`.
- `server/dataset/dataset.yaml`: YOLO config with train/val paths and `0: disc` class.
- `server/stats.json`: `total_samples`, `last_upload`.
- `server/models/*.tflite`: downloadable model artifacts; latest by file modification time.
- `server/training_data_export.zip`: generated export artifact.

### Relationships and Constraints

- A training sample id links full image, crop image, and label file by filename stem.
- A scored round has many `HoleScore` records, each has many `ThrowRecord` records, each references a `RouletteResult` challenge.
- Form analysis frames contain per-frame landmarks and angle maps; phase screens map selected frames to pro baseline phases.
- Knowledge-base articles link to source studies by study id.
- No SQL database, foreign keys, indexes, sharding, or migrations exist in the original system.

## 5. Business Logic Archaeology

### Domain Concepts

- Disc flight tracking: locate a disc in sampled video frames, smooth/interpolate a flight path, overlay the path, and optionally collect corrected keyframes as training samples.
- Form coaching: analyze throw videos using pose landmarks, compute biomechanical angles, compare to professional baselines by throw type/phase/player, surface score and suggestions, allow pose corrections, and save history.
- Disc Roulette: generate constrained random disc golf challenges involving shot shape, power, hindrance, disc selection, and putting style; optionally score rounds and weight strokes by challenge difficulty.
- Knowledge base: browse/search disc golf technique and biomechanics articles; optionally ask AI questions against the local article context.
- Model improvement loop: users opt in by keyframing/cropping disc frames; authenticated uploads expand the server YOLO dataset; operators retrain and distribute updated TFLite models.

### Embedded Business Rules

- Training sample ids are restricted to 1–80 letters/numbers/underscore/hyphen characters.
- YOLO labels must be a single class-0 row with normalized coordinates.
- Uploaded images must be non-empty JPEG/PNG files with matching magic bytes and must not exceed `MAX_UPLOAD_BYTES`.
- Training refuses to start with fewer than 10 full-image samples.
- Model version is determined from latest `.tflite` filename stem and SHA-256 hash.
- Onboarding is a one-time local flow controlled by `onboarding_complete`.
- Form Coach supports BH/FH phase names and mirrors/normalizes angle semantics for left-handed throwers where appropriate.
- Baseline deviations beyond statistical reference ranges drive coaching suggestions.
- Roulette scoring preserves a legacy `challenge` JSON format for older stored rounds while using multi-throw records for current scoring.
- Downloaded detector models are SHA-256 verified before local replacement.

## 6. End-User Experience Mapping

### Startup / Home

1. App starts, installs providers, applies dark theme.
2. Startup router reads SharedPreferences.
3. First launch shows onboarding; later launches show home.
4. Home routes into Flight Tracker, Form Coach, Roulette, Knowledge Base, Gallery, and Training Settings.

### Flight Tracker

1. User imports or records video.
2. App samples frames via thumbnail extraction.
3. TFLite detector processes frames; detections are filtered for spatial coherence, smoothed, interpolated, and rendered as an overlay.
4. User can switch to manual/keyframe tracking when automated detection is poor.
5. Corrected samples can be saved and optionally uploaded with an API key.

### Form Coach

1. User records/uploads and optionally trims a throw video.
2. User selects throw type/player/phase frames.
3. ML Kit pose detection extracts landmarks; angle calculator derives joint/trunk metrics.
4. App compares phase values to pro baselines, displays score/suggestions, and links to relevant knowledge-base articles.
5. User can correct skeleton/keypoints and save session history.

### Disc Roulette

1. User starts quick challenge or scored round.
2. Roulette wheel/generator selects shot constraints and optional disc/putt variations.
3. In scored play, players and pars are configured, hole throws are recorded, and raw/weighted scorecards are displayed.
4. History persists locally.

### Knowledge Base

1. User browses categories/articles or searches.
2. Article detail displays research-backed explanations and source study links.
3. Optional AI search requires user-provided Anthropic API key and sends bounded context to the external API.

## 7. Infrastructure & Operational Context

- Client deployment is standard Flutter platform builds. Android is the primary tested platform per README; other platform folders are generated/available.
- Server deployment supports Docker and Heroku-style Procfile. Docker uses Python 3.11-slim, installs requirements, exposes port `8000`, and starts Uvicorn.
- Server configuration:
  - `APP_API_KEY`: required at import/startup.
  - `CORS_ALLOW_ORIGINS`: optional comma-separated browser origins.
  - `MAX_UPLOAD_BYTES`: optional per-image upload cap; default 8 MiB.
- Client secrets:
  - Training API key stored in `flutter_secure_storage`.
  - Anthropic API key stored in `flutter_secure_storage`.
- Observability is minimal: FastAPI/Uvicorn access logs, in-memory training status, health endpoint, and local JSON feedback/history files. There is no structured JSON logging, metrics, tracing, or alerting.
- CI/CD: `.github/workflows/build.yml` is an Android APK build workflow on `main`/manual dispatch. It sets up Java 17 and Flutter 3.x, installs Android SDK/NDK 27.0.12077973 and Android 36 build tools, copies the Gradle init script, runs `flutter pub get`, checks required bundled assets, builds a release APK, and uploads it as an artifact. It does not run Flutter analysis/tests or server tests.

## 8. Test Coverage Analysis

- Flutter has a default widget smoke test that launches the app and expects a counter increment pattern; it does not match the current app UI and is not meaningful coverage.
- Server has `test_validation.py`, which directly validates sample id rules, YOLO label validation, image-extension normalization, and image signature validation.
- There are no meaningful Flutter unit tests for services/models, no golden/snapshot tests, no navigation tests, no integration tests for training upload/model download, no pose/detection fixture tests, and no end-to-end tests.
- There are no load/performance tests.

## 9. Known Pain Points / Debt

### TODO/FIXME/HACK/DEBT Search

No application TODO/FIXME/HACK/DEBT markers were found in `lib/`, `server/`, or prototype Python. Generated Flutter platform templates contain TODO comments in Linux/Windows CMake files about moving generated content into ephemeral files.

### Architectural Debt

- Most user-visible behavior lives in large stateful screens/services, making comprehensive tests difficult.
- Flutter test suite is stale and likely failing because it expects Flutter's starter counter app.
- Prototype Flask/Python bridge overlaps conceptually with Flutter-native ML services but is not integrated as a production runtime.
- Local persistence uses ad hoc JSON/SharedPreferences with limited versioning beyond a few legacy parsing branches.
- Server training state is in memory, so status is lost on process restart.
- Server training subprocess assumes `yolo` CLI availability and writes artifacts locally; no queue, cancellation, durable job store, or resource isolation exists.
- Dataset export writes a ZIP into the server directory synchronously per request.
- Model selection uses file modification time, which is operationally simple but not a deliberate versioning scheme.
- Observability is insufficient for production retraining failures or upload abuse investigation.

## Phase Boundary

Phase 1 is now documented. Per the request, Phase 2 synthesis and later rebuild work should not begin until this audit is reviewed and accepted as exhaustive enough for the rebuild baseline.
