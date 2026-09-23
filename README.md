# DiscFlightSchool

DiscFlightSchool is a monorepo containing a native Android client and a FastAPI training/model-distribution server for disc golf analysis workflows.

The client was a Flutter app until the Kotlin rewrite; `disc_golf_app/` is gone and its history is in git. This README describes only files and behavior that exist in this repository.

## Current repository status

### Android client (`disc_golf_android/`)

The Android app is the end-user application, written in Kotlin with Jetpack
Compose. `MainActivity` provides the process-wide `AppContainer` through a
composition local and hands off to `AppNavHost`, which routes first-time users
through onboarding before showing the home screen.

The Gradle project has two modules:

- **`:core`** — a plain Kotlin/JVM module with no Android dependencies. It holds
  the detection maths, tracking state machines, posture calculations, scoring,
  roulette, the knowledge-base search and Anthropic request/response handling,
  the server-URL allow-listing, and every persisted model. Because it is
  Android-free, all of it runs under a normal JVM test task.
- **`:app`** — the Android module: Compose UI, ML Kit and TensorFlow Lite
  integration, Media3 playback and export, frame extraction, storage, and the
  network client.

Implemented client areas currently present in source:

- Flight Tracker screens, video playback, overlays, and disc-detection services. Automated detection is track-by-detection: full-frame YOLO discovery locates the disc, then windowed tracking with velocity prediction follows it frame-to-frame (falling back to discovery after a short occlusion streak) instead of re-scanning the whole frame every time. A user-seeded keyframe path (`GeometricSplineTracker`/`HybridDiscTracker` behind the `DiscTracker` interface) remains available as a manual/hybrid alternative when automated tracking needs a correction. After trimming, the user picks "Auto-detect" or "Mark manually": auto runs `AutoDiscTracker` over the trimmed clip with no taps, showing determinate progress with a cancel, then reports a low-confidence warning (coverage, interpolated share, and mean confidence relative to the user's own sensitivity setting — see `core/detection/DetectionQuality.kt`) and offers to convert the detected path into editable keyframes for hand-correction. Every tracker works in the trimmed frame space: frame 0 is the trim start, not the start of the file.
- Form Coach screens for video trimming, posture analysis, phase selection/comparison, pose correction, and session history.
- Disc Roulette screens, scoring models, scoring repository, and roulette history.
- Knowledge Base screens and local JSON-backed content models/repositories.
- Training Settings for opt-in sample collection, server URL/API-key configuration, pending upload management, and detector model update checks.

Screen-to-screen state that is too large to encode in a navigation route — a
pose analysis, a flight path — lives in `WorkbenchState`; the routes
themselves carry only identifiers. Persistence is `SharedPreferences`,
`EncryptedSharedPreferences` for keys, and files under the app's own storage.

Important client facts:

- Gradle project: `disc_golf_android/`, modules `:app` and `:core`, built with the committed Gradle wrapper (8.11.1).
- Android Gradle Plugin `8.9.1`, Kotlin `2.1.0`, Compose BOM `2024.12.01`.
- Android application ID: `com.discflightschool.app`.
- `versionCode = 1`, `versionName = "1.0.0"`, declared in `disc_golf_android/app/build.gradle.kts`.
- `compileSdk = 36`, `targetSdk = 36`, `minSdk = 24`.
- Java/Kotlin target 17, with core library desugaring so `java.time` works at API 24.
- Release builds require a complete `disc_golf_android/key.properties` signing config; unsigned local testing should use debug builds.
- Bundled runtime assets live in `disc_golf_android/app/src/main/assets/`: `data/pro_baseline_db.json`, `data/knowledge_base.json`, and `models/disc_detector.tflite`.
- The bundled/retrained detector's TFLite output format needs no client-side parsing changes between YOLOv8 and YOLO11: both export the same anchor-free `Detect` head shape (verified against the `ultralytics` source, not assumed). `DiscDetector` reads its input tensor size and channel order from the loaded model at load time rather than assuming a fixed resolution or layout.
- **The bundled `disc_detector.tflite` is a genuine YOLO11n export at 640×640**, single class, dynamic-INT8-quantized (`quantize="w8a32"` — int8 weights, float32 activations, no calibration data needed). Read straight out of the flatbuffer to confirm rather than trust the filename: output `serving_default_output_0_output` is `[1,5,8400]` FLOAT32 — 8400 being 80²+40²+20², the anchor grid for a 640 input.
- **The input tensor is NCHW (channel-first), `[1,3,640,640]`, not the NHWC (channel-last) layout the app originally assumed.** As of Ultralytics 8.4.83 the standalone `tflite` export format was removed; `format="tflite"` now silently redirects to the `litert` exporter, which traces the PyTorch model directly and produces NCHW — there is no supported flag to recover the old onnx2tf-based NHWC output. `YoloOutput.detectInputLayout` distinguishes the two by which post-batch dimension equals 3 (the channel count — unambiguous, since a real detector's spatial dimensions are always ≥32) and `YoloPreprocessor.writeNormalizedInput` writes the pixel buffer in whichever order the loaded model actually expects.
- `DiscDetector` logs the loaded model's input/output shapes and detected channel order, and warns — but never fails — when the geometry doesn't match a single-class anchor-free `Detect` head: a non-multiple-of-32 input, an unexpected channel count, an anchor count that disagrees with the declared input size, or a shape it can't confidently classify as NHWC or NCHW. A model downloaded from the training server may legitimately ship at a different geometry, and refusing to load it would break detection outright instead of degrading.

#### Library choices carried over from the Flutter client

| Flutter package | Android replacement |
|---|---|
| `provider` | `AppContainer` + Compose state / `StateFlow` |
| `video_player` | Media3 ExoPlayer (`SeekParameters.EXACT` for frame-accurate scrubbing) |
| `ffmpeg_kit_flutter_new` | `MediaMetadataRetriever` for frame extraction, Media3 `Transformer` + `OverlayEffect` for the burned-in flight path |
| `tflite_flutter` | `org.tensorflow:tensorflow-lite`, with the GPU delegate and a CPU fallback |
| `google_mlkit_pose_detection` | `com.google.mlkit:pose-detection-accurate` |
| `image_picker` / `file_picker` | `ActivityResultContracts.PickVisualMedia` / `CaptureVideo` |
| `flutter_secure_storage` | `EncryptedSharedPreferences` |
| `shared_preferences` | `SharedPreferences` |
| `gal` | `MediaStore` |
| `share_plus` | `FileProvider` + `ACTION_SEND` |
| `http` | OkHttp |
| `archive` / `crypto` | `java.util.zip` / `MessageDigest` |

Frame extraction is the one substitution with a behavioural note worth knowing:
`MediaMetadataRetriever` is asked for `OPTION_CLOSEST` rather than the cheaper
`OPTION_CLOSEST_SYNC`, because snapping to the nearest keyframe would silently
misalign an overlay from the position it was measured at.

The on-disk formats — landmark key strings, ISO-8601 timestamps, the legacy
`challenge` field on a saved hole, the `uploaded` flag on a training sample —
are unchanged from the Flutter client, so an existing install keeps its
history. `DataContractsTest` covers those round trips.

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
| `POST` | `/api/disc-flight/jobs` | `X-App-Key` | Uploads a supported throw video and starts one persistent Roboflow WebRTC Workflow session. |
| `GET` | `/api/disc-flight/jobs/{id}` | `X-App-Key` + `X-Job-Token` | Returns honest job phase, frame counts, and progress when a reliable total is available. |
| `GET` | `/api/disc-flight/jobs/{id}/result` | `X-App-Key` + `X-Job-Token` | Streams the completed annotated MP4. |
| `DELETE` | `/api/disc-flight/jobs/{id}` | `X-App-Key` + `X-Job-Token` | Cancels processing and removes temporary input/output files. |

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
- `object-storage`
- `cloudflared` (optional, `--profile tunnel`)

`training-api` and `training-worker` both run with the durable env vars set, so this stack exercises `PostgresMinioStorage` and the Redis training queue, not the filesystem backend. `./scripts/test_compose_integration.sh` boots this stack and exercises it end-to-end (see `.github/workflows/compose-integration.yml`, which runs it on push to `main`).

## Project layout

```text
DiscFlightSchool/
├── .github/workflows/          # GitHub Actions for the Android build/tests and server tests
├── disc_golf_android/          # Android application (Gradle)
│   ├── app/                    # Android module: Compose UI, ML Kit, TFLite, Media3
│   │   └── src/main/assets/    # JSON data and the bundled TFLite detector
│   ├── core/                   # Pure Kotlin/JVM module: detection, tracking, posture,
│   │                           #   scoring, and the persisted models, with its tests
│   └── art/                    # Source artwork for the launcher icon and basket drawable
├── docs/                       # testing.md, dependency-audit-troubleshooting.md,
│   │                           #   and the Google Play readiness report/plan
│   └── studies/                # The research papers the knowledge base cites
├── scripts/                    # Local test and validation scripts
├── server/                     # FastAPI training/model server
│   ├── training_server/        # App factory, config, storage, training, validation, worker
│   ├── requirements.txt        # Production runtime pins
│   ├── requirements-test.txt   # Test env pins (must agree; enforced by test_requirements.py)
│   └── test_*.py               # Server tests
└── docker-compose.yml          # API/worker/Postgres/Redis/MinIO scaffold
```

The Flutter client that preceded this one accumulated several layers of dead
code, all removed before the rewrite: a never-called prototype Flask service
and its bridge, a never-routed Flight Analysis screen with the services,
assets, models, and helpers behind it, and two other unrouted screens. One
more — `comparison_screen.dart`, which nothing navigated to — was found during
the port and deliberately not carried over. Recover any of it from git history
if you want to revive that path.

## Local development

### Server checks

```bash
# requirements-test.txt omits ultralytics (torch) but pins every shared
# dependency identically to requirements.txt; test_requirements.py fails the
# build if the two ever drift.
python -m pip install -r server/requirements-test.txt
APP_API_KEY=test-key ./scripts/test_server.sh
```

### Roboflow disc-flight processing

The Android Flight Tracker can preview an imported/recorded throw and send it
to the existing FastAPI server. The server, never the application, reads
`ROBOFLOW_API_KEY`. It sends the entire video in frame order through one
persistent WebRTC session for workspace `disc-golf-tracer`, Workflow
`disc-golf-flight-tracker-1789645514948`, and image input `image`. The
Workflow's `output_image` is the canonical visualization; the client does not
reimplement OC-SORT or trajectory rendering.

Local setup:

```bash
python -m venv .venv
. .venv/bin/activate
pip install -r server/requirements.txt
export APP_API_KEY="$(python -c 'import secrets; print(secrets.token_urlsafe(32))')"
export ROBOFLOW_API_KEY='your-server-side-key'
uvicorn main:app --app-dir server --host 0.0.0.0 --port 8000
```

In Android **Training Settings**, set the server URL and the matching
`APP_API_KEY`, then run the client with Android Studio or:

```bash
cd disc_golf_android
./gradlew :app:installDebug
```

Accepted uploads are MP4, MOV, WebM, and MKV. The default limit is 200 MiB
(`DISC_FLIGHT_MAX_UPLOAD_BYTES=209715200`) and the default session timeout is
15 minutes (`DISC_FLIGHT_SESSION_TIMEOUT_SECONDS=900`). Job results are stored
under `server/disc_flight_jobs/`, which is ignored by Git. The current
in-process job registry is appropriate for a single API process; a deployment
using multiple API replicas must move job state to its shared queue/database
before scaling the API horizontally.

Normal tests mock Roboflow and consume no credits:

```bash
APP_API_KEY=test-key ./scripts/test_server.sh
./scripts/test_android.sh
```

The real integration is deliberately opt-in and needs a short throw video:

```bash
ROBOFLOW_API_KEY='server-only-key' \
ROBOFLOW_TEST_VIDEO=/absolute/path/to/short-throw.mp4 \
python scripts/test_roboflow_integration.py
```

It verifies that OpenCV can open the resulting annotated MP4. A release is
still not end-to-end verified until that output is also played in the Android
app on a device. Rotate a Roboflow credential in the Roboflow dashboard, update
only the server secret manager/environment, and restart the API. Never put the
key in Android source, resources, `BuildConfig`, client-readable configuration,
an APK, or Git history.

#### Single-image disc detection

`server/training_server/disc_detection.py` sends one still image through a
second published Workflow in the same workspace:
`disc-golf-flight-tracker-vdisc-golf-flight-tracker-2-rfdetr-small-t1-logic`.
That Workflow wraps the `disc-golf-flight-tracker-2-rfdetr-small-t1` RF-DETR
model. It takes one input, `image`, declares no runtime parameters, and
returns one JSON output, `predictions`, which holds the image size and a list
of boxes. It returns no annotated image. Video still goes through the WebRTC
path described earlier, and no HTTP endpoint calls this module.

```python
from pathlib import Path

from training_server.config import Settings
from training_server.disc_detection import DiscDetectionError, detect_discs

settings = Settings.from_env()
try:
    result = detect_discs(Path("frame.jpg"), api_key=settings.roboflow_api_key)
except DiscDetectionError as error:
    ...  # every failure is a subclass of this
for box in result.detections:
    print(box.class_name, box.confidence, box.x, box.y, box.width, box.height)
```

The module behaves as follows:

- The image is encoded JPEG or PNG bytes, a local file path, or an `https://`
  URL. Plain `http://` URLs are rejected. inference-sdk downloads a URL on the
  server before uploading it, so validate any URL that a client supplies.
- The key comes from `ROBOFLOW_API_KEY`, as for video, and travels only in the
  `Authorization: Bearer` header.
- Each attempt has a 30-second timeout. Connection failures, timeouts, and
  HTTP 429, 500, 502, 503, and 504 responses are retried twice, 0.5 seconds
  and then 1 second apart. Any other failure is raised at once.
  inference-sdk's own retries are turned off so that the two don't compound.
- Failures raise `DiscDetectionNotConfigured`, `DiscDetectionInputError`,
  `DiscDetectionRequestError` (which carries `status_code`),
  `DiscDetectionTimeout`, or `DiscDetectionResponseError`.
- Box coordinates are pixels in the submitted image, and `x`/`y` is the box
  center.

`server/test_disc_detection.py` replays a response captured from the real
Workflow, so it needs no key and spends no credits. Its three tests that drive
the real SDK against a local stub server skip when `inference-sdk` isn't
installed, as in CI. The live check is opt-in:

```bash
ROBOFLOW_API_KEY='server-only-key' \
ROBOFLOW_TEST_IMAGE=/absolute/path/to/throw-frame.jpg \
python scripts/test_roboflow_image_workflow.py
```

`ROBOFLOW_TEST_IMAGE` also accepts an `https://` URL. Without it, the script
sends a generated frame. The script fails unless the response contains the
`predictions` output with its `image` and `predictions` fields.

### Android checks

```bash
./scripts/test_android.sh
```

The script runs `:core:test` and `:app:testDebugUnitTest` through the committed
Gradle wrapper, so the only host requirement is a JDK 17 plus the Android SDK
for the `:app` module. `:core` alone needs nothing but the JDK:

```bash
cd disc_golf_android
./gradlew :core:test
```

## Building a testable Android APK

Prerequisites:

1. Java 17.
2. Android SDK with compile SDK 36 and build tools installed (`ANDROID_HOME`, or a `local.properties` naming `sdk.dir`).
3. Network access for first-time dependency resolution unless dependencies are already cached.

Recommended validation/build sequence:

```bash
cd disc_golf_android
./gradlew :core:test :app:testDebugUnitTest
./gradlew :app:lintDebug
./gradlew :app:assembleDebug
```

Expected debug APK output:

```text
disc_golf_android/app/build/outputs/apk/debug/app-debug.apk
```

For a signed release build, add `disc_golf_android/key.properties` with `keyAlias`, `keyPassword`, `storeFile`, and `storePassword`, then run:

```bash
cd disc_golf_android
./gradlew :app:assembleRelease     # APK
./gradlew :app:bundleRelease       # AAB, what Play Console takes
```

Without `key.properties` the release build has no signing config and fails; use `:app:assembleDebug` for local unsigned testing.

### Bumping the app version for a release

`versionCode` and `versionName` live in `disc_golf_android/app/build.gradle.kts`. **Increment `versionCode` on every release submitted to an app store**, even for a patch that only changes `versionName`: Google Play rejects a re-upload whose version code doesn't strictly increase over the previous release.

## Current next steps

1. **TODO: build and run the Kotlin client on a device.** The rewrite has
   been verified at the logic level — `:core`'s suite covers every ported
   calculation, and `:app`'s unit tests cover the Android-free helpers — but
   nothing here has exercised Compose, ML Kit, TensorFlow Lite, Media3, or
   `MediaMetadataRetriever` against a real device. Assemble a debug APK and
   walk each feature end to end; `docs/testing.md` has the checklist.
2. **TODO: verify the YOLO11n@640 detector on a real device with a real
   throw video.** The `.tflite` swap and the NCHW-layout handling it required
   (see the client facts above) are done, but none of it has run against a
   real TFLite interpreter yet. Confirm the load log reports
   `input [1, 3, 640, 640]` and `NCHW` before trusting anything else.
3. Keep docs synchronized with source whenever endpoints, assets, build settings, or runtime services change.
4. **Measure detection timing at 640 and decide where inference runs.**
   Per-frame cost scales with input area, so a 640 model is roughly 4× the 320
   export's inference, output marshalling, and candidate scan. Detection
   already runs off the main thread on a background dispatcher and reuses its
   direct `ByteBuffer`s, and the frame budget is derived from the trimmed span
   (a six-second trim is ~61 frames, not the 300-frame cap), but measure on a
   device before deciding whether a foreground service or a `WorkManager` job
   is needed for long clips. See `docs/testing.md`.

## Running the compose stack

`docker-compose.yml` reads `server/.env.example` for non-secret defaults but
requires every credential to be supplied by your shell, so the committed
placeholders can never become live credentials:

```bash
export APP_API_KEY="$(python -c 'import secrets; print(secrets.token_urlsafe(32))')"
export POSTGRES_DB=discflight POSTGRES_USER=discflight
export POSTGRES_PASSWORD='...' OBJECT_STORAGE_ROOT_USER='...' OBJECT_STORAGE_ROOT_PASSWORD='...'
docker compose up
```

#### Reaching the stack from the Android client

The client refuses plain HTTP anywhere but loopback, so a phone needs the server
over HTTPS. The `cloudflared` service publishes it through a Cloudflare Tunnel
with no open port, no certificate to manage, and no public IP:

1. Create a tunnel in the Cloudflare dashboard and point its public hostname at
   `http://training-api:8000`.
2. Export the token it gives you, and the Roboflow key if you want cloud
   tracing: `export CLOUDFLARE_TUNNEL_TOKEN='...' ROBOFLOW_API_KEY='...'`.
3. Start the stack with the profile: `docker compose --profile tunnel up`.
4. In Training Settings, enter the tunnel's `https://` hostname and the same
   `APP_API_KEY`.

A free Cloudflare Tunnel rejects request bodies over 100 MB, below the 200 MiB
upload default, so lower the limit to match and let the server return its own
413: `export DISC_FLIGHT_MAX_UPLOAD_BYTES=99000000`.

Changing the server URL to a different origin clears the stored API key by
design, so prefer a stable hostname over one that changes per restart.
