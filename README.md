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
  roulette, the knowledge-base search,
  the server-URL allow-listing, and every persisted model. Because it is
  Android-free, all of it runs under a normal JVM test task.
- **`:app`** — the Android module: Compose UI, ML Kit and TensorFlow Lite
  integration, Media3 playback and export, frame extraction, storage, and the
  network client.

Implemented client areas currently present in source:

- Flight Tracker screens, video playback, overlays, and disc-detection services. Automated detection runs the Roboflow Workflow `disc-golf-flight-tracker` on the phone: its RF-DETR Small disc model (ONNX Runtime) scores every frame at 30 fps, and an OC-SORT tracker ported from the Workflow's `trackers_ocsort@v1` step links the detections, with the Workflow's own settings (see "The on-device disc model" below). A user-seeded keyframe path (`GeometricSplineTracker`/`HybridDiscTracker` behind the `DiscTracker` interface) remains available as a manual/hybrid alternative; the hybrid tracker refines the hand-marked path with the same RF-DETR model, searching a window around each predicted position. After trimming, the user picks "Auto-detect" or "Mark manually": auto runs `WorkflowDiscTracker` over the trimmed clip with no taps, showing determinate progress with a cancel, then reports a low-confidence warning (coverage, interpolated share, and mean confidence relative to the Workflow's 0.15 threshold — see `core/detection/DetectionQuality.kt`) and offers to convert the detected path into editable keyframes for hand-correction. Every tracker works in the trimmed frame space: frame 0 is the trim start, not the start of the file.
- Form Coach screens for video trimming, posture analysis, phase selection/comparison, pose correction, and session history.
- Disc Roulette screens, scoring models, scoring repository, and roulette history.
- Knowledge Base screens and local JSON-backed content models/repositories.
- Training Settings for opt-in sample collection, server URL/API-key configuration, and pending upload management.

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
- Bundled runtime assets live in `disc_golf_android/app/src/main/assets/`: `data/pro_baseline_db.json`, `data/knowledge_base.json`, and the disc model in `models/rfdetr/` (`weights.onnx`, `inference_config.json`, `class_names.txt`, `package.json`).
- **The disc model isn't committed.** Its weights are about 114 MB, over GitHub's file limit, so `models/rfdetr/` is git-ignored and `scripts/fetch_disc_model.py` downloads it (see "The on-device disc model"). A debug build without it installs, but Auto-detect reports that the model couldn't load; a release build stops with an error instead.

#### Library choices carried over from the Flutter client

| Flutter package | Android replacement |
|---|---|
| `provider` | `AppContainer` + Compose state / `StateFlow` |
| `video_player` | Media3 ExoPlayer (`SeekParameters.EXACT` for frame-accurate scrubbing) |
| `ffmpeg_kit_flutter_new` | `MediaMetadataRetriever` for frame extraction, Media3 `Transformer` + `OverlayEffect` for the burned-in flight path |
| `tflite_flutter` | `com.microsoft.onnxruntime:onnxruntime-android`, running the Roboflow RF-DETR model on the CPU |
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
| `GET` | `/ready` | No | Returns `{"status":"ok"}` when storage answers, or 503. |
| `POST` | `/api/training/upload` | `X-App-Key` or upload key | Validates sample ID, YOLO class-0 label, positive dimensions, JPEG/PNG signatures, and stores full image, crop image, and label on disk. |
| `GET` | `/api/training/stats` | `X-App-Key` | Returns stored stats and on-disk image/label counts. |
| `GET` | `/api/training/export` | `X-App-Key` | Builds and returns a ZIP of the dataset directory when data exists. |
| `POST` | `/api/training/start` | `X-App-Key` | Starts a background YOLO11 (`yolo11n.pt`) training/export thread if at least 10 full images exist. |
| `GET` | `/api/training/status` | `X-App-Key` | Returns training status (in-memory, or from PostgreSQL in durable mode — same JSON shape either way). |
| `GET` | `/api/model/version` | No | Returns latest `.tflite` model metadata or the no-model sentinel. |
| `GET` | `/api/model/download` | No | Downloads the latest `.tflite` model or returns 404 when none exists. |
| `POST` | `/api/disc-flight/jobs` | `X-App-Key` or client key | Uploads a supported throw video and starts one persistent Roboflow WebRTC Workflow session. Optional `start_ms` and `end_ms` form fields limit processing to that part of the video. |
| `GET` | `/api/disc-flight/jobs/{id}` | `X-App-Key` or client key, + `X-Job-Token` | Returns honest job phase, frame counts, and progress when a reliable total is available. |
| `GET` | `/api/disc-flight/jobs/{id}/result` | `X-App-Key` or client key, + `X-Job-Token` | Streams the completed annotated MP4. |
| `GET` | `/api/disc-flight/jobs/{id}/track` | `X-App-Key` or client key, + `X-Job-Token` | Returns the disc's normalized position in each frame where the Workflow found it. |
| `DELETE` | `/api/disc-flight/jobs/{id}` | `X-App-Key` or client key, + `X-Job-Token` | Cancels processing and removes temporary input/output files. |
| `POST` | `/api/disc-detection` | `X-App-Key` or client key | Runs one JPEG/PNG image through the Roboflow disc-detection Workflow and returns the disc boxes. |

Important server facts:

- `APP_API_KEY` is required to start the server.
- `CLIENT_API_KEY` is optional, and it's accepted only by the Roboflow endpoints marked "client key" in the endpoint table, never by the training upload, export, or start endpoints. The Android app no longer sends it: disc detection runs on the device. For more information, see "The client key" later in this README.
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
│   ├── requirements-roboflow.txt  # Roboflow endpoint packages (install with requirements.txt)
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
pip install -r server/requirements.txt -r server/requirements-roboflow.txt
export APP_API_KEY="$(python -c 'import secrets; print(secrets.token_urlsafe(32))')"
export ROBOFLOW_API_KEY='your-server-side-key'
uvicorn main:app --app-dir server --host 0.0.0.0 --port 8000
```

The app uses the server only for training uploads; disc detection runs on the
device. To point a build at your own server, set the server URL and the
matching `APP_API_KEY` in Android **Training Settings**, then run the client
with Android Studio or:

```bash
cd disc_golf_android
./gradlew :app:installDebug
```

Accepted uploads are MP4, MOV, WebM, and MKV. The default limit is 200 MiB
(`DISC_FLIGHT_MAX_UPLOAD_BYTES=209715200`) and the default session timeout is
15 minutes (`DISC_FLIGHT_SESSION_TIMEOUT_SECONDS=900`). Job results are stored
under `server/disc_flight_jobs/`, which is ignored by Git, and are deleted 24
hours after the job finishes, along with any job folders a previous server
process left behind. The current
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

It verifies that OpenCV can open the resulting annotated MP4 and that the
per-frame track holds positions inside the frame. A release is
still not end-to-end verified until that output is also played in the Android
app on a device. Rotate a Roboflow credential in the Roboflow dashboard, update
only the server secret manager/environment, and restart the API. Never put the
key in Android source, resources, `BuildConfig`, client-readable configuration,
an APK, or Git history.

#### Clip range and per-frame track

`POST /api/disc-flight/jobs` takes two optional multipart fields, `start_ms`
and `end_ms`. When either is present, the server copies only that range of the
upload into a new MP4 before it opens the Roboflow session, because inference
credits are spent per frame. A range that starts past the end of the video
fails the job with "The selected part of the video has no frames."

When a job completes, its status includes `trackUrl`. That endpoint returns the
highest-confidence disc box in each frame, preferring the Workflow's
`tracked_disc` output and falling back to `disc_detections`:

```json
{
  "fps": 30.0,
  "frameCount": 90,
  "detections": [
    {"frame": 0, "timeMs": 0, "x": 0.412, "y": 0.633,
     "width": 0.021, "height": 0.018, "confidence": 0.87}
  ]
}
```

Frame 0 is the first frame of the processed range, and `timeMs` counts from
there. `x`/`y` is the box center, and every value is a fraction of the frame
width or height. The Android app doesn't call these endpoints: its
**Auto-detect** runs the same Workflow on the device.

#### The client key

`CLIENT_API_KEY` is a second, separate server key that the Roboflow endpoints
accept, so a client can reach them without the server's `APP_API_KEY`. Earlier
Android builds shipped with it; builds from this version on run disc detection
on the device and send no key to these endpoints.

Because a shipped key can be extracted from an APK, treat it as public: it
opens only the Roboflow endpoints, so its worst case is spent inference
credits. The server bounds that: it runs at most `DISC_FLIGHT_MAX_ACTIVE_JOBS`
video jobs at once, and limits client-key requests per caller
(`CLIENT_RATE_LIMIT_PER_HOUR`) and in total (`CLIENT_GLOBAL_LIMIT_PER_HOUR`),
answering 429 past either. On Render, set `TRUSTED_PROXY_HOPS=1` so the
per-caller limit sees real client addresses. Once no installed build sends
the key, unset `CLIENT_API_KEY` on the server to close the endpoints to
everything but `APP_API_KEY`.

#### Single-image disc detection

`server/training_server/disc_detection.py` sends one still image through a
second published Workflow in the same workspace:
`disc-golf-flight-tracker-vdisc-golf-flight-tracker-2-rfdetr-small-t1-logic`.
That Workflow wraps the `disc-golf-flight-tracker-2-rfdetr-small-t1` RF-DETR
model. It takes one input, `image`, declares no runtime parameters, and
returns one JSON output, `predictions`, which holds the image size and a list
of boxes. It returns no annotated image. Video still goes through the WebRTC
path described earlier.

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

`POST /api/disc-detection` exposes the module over HTTP. It takes the image as
a multipart field named `image`, requires `X-App-Key`, and applies the same
JPEG/PNG checks and `MAX_UPLOAD_BYTES` limit as training uploads. It doesn't
accept URLs, so the server never fetches an address a client supplies.

```bash
curl -H "X-App-Key: $APP_API_KEY" -F image=@frame.jpg \
  https://your-server.example.com/api/disc-detection
```

A successful call returns HTTP 200:

```json
{
  "imageWidth": 576,
  "imageHeight": 1024,
  "detections": [
    {"x": 228.0, "y": 521.0, "width": 40.0, "height": 22.0,
     "confidence": 0.82, "className": "disc"}
  ]
}
```

The endpoint returns these error statuses:

| Status | Meaning |
|---:|---|
| `400` | The image is missing, too large, or not a decodable JPEG/PNG. |
| `403` | `X-App-Key` is missing or wrong. |
| `502` | Roboflow failed or answered in an unexpected shape. |
| `503` | `ROBOFLOW_API_KEY` isn't set on the server. |
| `504` | Every attempt timed out. |

A `502` or `504` response doesn't include Roboflow's error. The server logs
it as a `disc_detection.failed` event with the request ID, the error type, and
the upstream HTTP status when there is one. The call can block for about 90
seconds when every attempt times out, and each call spends inference credits.

`server/test_disc_detection.py` covers the module and the endpoint by
replaying a response captured from the real Workflow, so it needs no key and
spends no credits. Its three tests that drive the real SDK against a local
stub server skip when `inference-sdk` isn't installed, as in CI. The live
check is opt-in:

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

### The on-device disc model

Auto-detect runs the Roboflow Workflow `disc-golf-flight-tracker` on the
phone, with no server and no Roboflow credits:

1. **Detect.** `RfDetrDiscDetector` runs the Workflow's model,
   `disc-golf-tracer/disc-golf-flight-tracker-2-rfdetr-small-t1` (RF-DETR
   Small, 512x512, Apache 2.0), with ONNX Runtime. `core/detection/RfDetr.kt`
   ports Roboflow's preprocessing (Pillow's bilinear stretch resize, then
   ImageNet normalization) and post-processing, and refuses a package whose
   `inference_config.json` asks for anything it doesn't implement.
2. **Filter and track.** `WorkflowDiscTracker` keeps the `disc` class above
   the Workflow's 0.15 confidence and links frames with `OcSortTracker`, a
   port of the `trackers` 2.4.0 OC-SORT the Workflow's `trackers_ocsort@v1`
   step uses, with the same settings.
3. **Pick each frame's disc** as the server did: the most confident tracked
   box, otherwise the most confident detection.

`OcSortTrackerTest` and `RfDetrTest` check the ports against fixtures the
Python libraries produced (`scripts/generate_ocsort_fixture.py` and
`scripts/generate_pil_resize_fixture.py`). Two things differ from the hosted
Workflow: frames are decoded at 30 fps rather than the clip's own rate, and
Android's decoder may produce slightly different pixels from the server's.

The weights aren't committed. `scripts/fetch_disc_model.py` downloads
Roboflow's ONNX export of the model from the same weights API self-hosted
Inference uses, checks each file's MD5, and writes them to
`disc_golf_android/app/src/main/assets/models/rfdetr/`. It needs the
workspace's private key in `ROBOFLOW_API_KEY`, which never goes into the APK.
CI runs it before every build from the `ROBOFLOW_API_KEY` repository secret,
and `.github/workflows/fetch-roboflow-model.yml` prints the downloaded
package's settings and graph. After retraining in Roboflow, run the script
again (with `--model-id` if the Workflow's `model_id` input changed) and
rebuild.

## Building a testable Android APK

Prerequisites:

1. Java 17.
2. Android SDK with compile SDK 36 and build tools installed (`ANDROID_HOME`, or a `local.properties` naming `sdk.dir`).
3. Network access for first-time dependency resolution unless dependencies are already cached.
4. The disc model, downloaded once with the Roboflow workspace's private API key (see "The on-device disc model"):

   ```bash
   ROBOFLOW_API_KEY=... python3 scripts/fetch_disc_model.py
   ```

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

CI builds the minified release bundle on every pull request
(`.github/workflows/release-build.yml`, job `release-build-check`), signed
with a throwaway key, so an R8 shrinking break fails CI instead of a release.
To produce the bundle you upload to Google Play, run that workflow manually:
its `signed-bundle` job signs with your upload key and attaches
`app-release.aab` to the run. It needs these repository secrets:

| Secret | Value |
|---|---|
| `RELEASE_KEYSTORE_BASE64` | The upload keystore, base64-encoded: `base64 -w0 upload.jks`. |
| `RELEASE_STORE_PASSWORD` | The keystore password. |
| `RELEASE_KEY_ALIAS` | The key's alias in the keystore. |
| `RELEASE_KEY_PASSWORD` | The key's password. |
| `ROBOFLOW_API_KEY` | The Roboflow workspace's private API key, for downloading the disc model. |

### The public privacy policy

Google Play needs the privacy policy at a public URL.
`docs/privacy-policy.md` is that copy, ready to publish with GitHub Pages (or
anywhere else that serves Markdown or HTML). `PrivacyPolicyTest` fails when it
differs from the in-app text in `PrivacyPolicy.kt`, so change both together.

### Bumping the app version for a release

`versionCode` and `versionName` live in `disc_golf_android/app/build.gradle.kts`. **Increment `versionCode` on every release submitted to an app store**, even for a patch that only changes `versionName`: Google Play rejects a re-upload whose version code doesn't strictly increase over the previous release.

## Current next steps

1. **TODO: build and run the Kotlin client on a device.** The rewrite has
   been verified at the logic level — `:core`'s suite covers every ported
   calculation, and `:app`'s unit tests cover the Android-free helpers — but
   nothing here has exercised Compose, ML Kit, ONNX Runtime, Media3, or
   `MediaMetadataRetriever` against a real device. Assemble a debug APK and
   walk each feature end to end; `docs/testing.md` has the checklist.
2. **TODO: time the RF-DETR disc model on a real device.** Auto-detect runs
   RF-DETR Small at 512x512 on up to 300 frames (10 seconds at 30 fps). Its
   speed on a phone CPU hasn't been measured; the load log lists the model's
   inputs and outputs, and each frame's progress is shown in the dialog.
3. Keep docs synchronized with source whenever endpoints, assets, build settings, or runtime services change.
4. **Decide where inference runs once it's timed.** Detection runs off the
   main thread, and the frame budget is derived from the trimmed span (a
   six-second trim is 181 frames at 30 fps, not the 300-frame cap). Measure
   on a device before deciding whether a foreground service or a
   `WorkManager` job is needed for long clips.

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
