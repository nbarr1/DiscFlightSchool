# Testing

## Roboflow flight path

Automated backend and Android tests use fake HTTP/WebRTC responses and never
spend inference credits. Run the server suite with `APP_API_KEY=test-key
./scripts/test_server.sh` and Android tests with `./scripts/test_android.sh`.

For the opt-in real Workflow check, install `server/requirements.txt` and
`server/requirements-roboflow.txt`, set
`ROBOFLOW_API_KEY` and `ROBOFLOW_TEST_VIDEO` to a short throw, then run
`python scripts/test_roboflow_integration.py`. The same check runs in CI as
`Roboflow Workflow Smoke Test`, which is manual dispatch only because each run
spends inference credits: it reads the `ROBOFLOW_API_KEY` repository secret,
takes an optional `video_url` input, and uploads the annotated MP4 and the
per-frame track JSON as an artifact. Without a `video_url` it generates a
synthetic clip of a white dot on an arc. The Workflow detects the dot, so the
run also checks each tracked position against the dot's known path, which
catches a track whose frame numbering or scaling is off. It says nothing about
accuracy on real footage. The optional `clip_ms` input, such as `500,2500`,
processes only that range, as the app's Auto-detect does. The `video_url` has
to download the file itself: a share page such as a Google Drive `.../view`
link downloads HTML, which the script rejects before calling Roboflow. Confirm
the generated MP4 opens, then verify on a device: pick and record, preview,
process, progress/indeterminate processing, playback, sharing, retry,
cancellation, and duplicate-tap prevention on the Flight Tracker screen, and
Auto-detect on a trimmed clip in the flight player, including its fallback to
the on-device detector with the network off. Do not mark the mobile
integration verified until the annotated result plays there and Auto-detect
draws the trail.

## Roboflow single-image detection

`server/test_disc_detection.py` replays a response captured from the real
Workflow and spends no credits. Its three tests that drive the real
`inference-sdk` against a local stub server check the request URL, the
`Authorization: Bearer` header, the payload, and the retry count. They skip
when `inference-sdk` isn't installed, which is the case in CI.

For the opt-in real Workflow check, install `server/requirements.txt` and
`server/requirements-roboflow.txt`, set
`ROBOFLOW_API_KEY`, and run `python scripts/test_roboflow_image_workflow.py`.
Set `ROBOFLOW_TEST_IMAGE` to a throw frame's path or `https://` URL to test a
real image. Without it, the script sends a generated frame. The script fails
unless the response contains the `predictions` output with its `image` and
`predictions` fields. Each run spends inference credits.

## Running the suites

```bash
# Server (no Docker, no ultralytics/torch needed)
python -m pip install -r server/requirements-test.txt
APP_API_KEY=test-key ./scripts/test_server.sh

# Android
./scripts/test_android.sh          # :core:test + :app:testDebugUnitTest
```

`:core` is a plain Kotlin/JVM module, so `./gradlew :core:test` alone needs
nothing but a JDK 17 — no Android SDK.

CI runs both on every pull request (`.github/workflows/server-tests.yml`,
`android-tests.yml`, which also runs Android Lint) plus a dependency audit
(`dependency-audit.yml`).

## Server coverage

| File | Covers |
|---|---|
| `test_validation.py` | sample-id and YOLO-label validators, image signature/extension checks, `safe_child` path-traversal guard |
| `test_storage.py` | `FileStorage` behaviour — atomic writes, duplicate rejection, oversize/corrupt/decompression-bomb uploads, export contents, model-info caching, stats round-trip |
| `test_http_contracts.py` | endpoint contracts driven through raw ASGI: auth on every protected route, upload validation ordering, request-id propagation, export cleanup |
| `test_training_manager.py` | the `running` state machine — every rejection path must release the flag so training stays retryable |
| `test_config.py` | environment parsing and validation |
| `test_requirements.py` | production and test dependency pins cannot drift |
| `test_disc_detection.py` | single-image Roboflow Workflow client and `POST /api/disc-detection`: response parsing, input checks, per-attempt timeout, which failures retry, typed errors, the endpoint's status codes, and upload cleanup |

Two guardrails worth knowing about, because they encode past incidents:

- **`test_requirements.py`** exists because CI once installed
  `Pillow>=10.0.0,<12.0.0` while production required `Pillow>=12.3.0` — two
  ranges with no overlap, so image validation was tested against a major
  version the app would never run.
- **`scripts/validate_durable_runtime.py`** asserts that `docker-compose.yml`
  requires `APP_API_KEY`, `POSTGRES_PASSWORD`, and `MINIO_ROOT_PASSWORD` as
  shell overrides. Compose reads `server/.env.example` for defaults, so without
  those overrides the committed placeholder API key would become a live
  credential on any stack someone starts.

## Android coverage

Everything ported out of Dart that can be tested without a device lives in
`:core`, which is why the suite concentrates there.

| File | Covers |
|---|---|
| `AngleCalculatorTest.kt` | 2-D/3-D joint angles, X-factor sign and magnitude, Catmull-Rom control-point interpolation, anchor filling |
| `ScoringRepositoryTest.kt` | round persistence (including the undo/re-enter duplicate-save regression), corrupt-store resilience, statistics |
| `PostureMathTest.kt` | lead/trail knee labelling per throw type, physiological-limit clamping vs dropping, angle and keypoint smoothing, pro deviation scoring |
| `KnowledgeSearchTest.kt` | local keyword search: tokenizing, ranking, source citations, and the no-keyword and no-match messages |
| `DiscDetectionTest.kt` | candidate selection, spatial-coherence filtering, smoothing, gap interpolation, frame-index alignment |
| `RfDetrTest.kt` | the RF-DETR package config (and refusing settings the port doesn't implement), Pillow's bilinear resize against `pil_resize_fixture.json`, normalization, and output decoding: top-k, the strict threshold, and box scaling |
| `OcSortTrackerTest.kt` | the OC-SORT port against `ocsort_fixture.json`, which `trackers` 2.4.0 produced for six scenarios, plus id assignment and the confidence threshold |
| `WorkflowDiscTrackerTest.kt` | each frame's disc choice, mapping 30 fps Workflow frames onto the session's frames, gap filling, the request sent to the detector, load failure, and the 300-frame cap |
| `DetectionQualityTest.kt` | the coverage/interpolation/confidence heuristic, its thresholds against the user's sensitivity setting, and seed-point sampling |
| `TrackerTest.kt` | the spline tracker, the frame budget derived from a trimmed span, and frame-index maths |
| `WorldAnchorTest.kt` | the similarity transform that keeps a flight path pinned to the scene while the camera pans and zooms |
| `ServerUriTest.kt` | server URL allow-listing, same-origin checks, endpoint construction |
| `RouletteTest.kt` | disc/power/shape generation, incompatible-combination filtering, difficulty weighting |
| `DataContractsTest.kt` | the persisted formats — landmark keys, ISO timestamps, legacy fields — that an upgrading install still has to read |

`:app`'s own unit tests cover the helpers that are Android-free but live in the
Android module: `FormattingTest.kt` (scorecard and history readouts),
`FrameIndexTest.kt` and `FrameForFractionTest.kt` (timestamp-to-frame maths),
`FlightVideoExporterTest.kt` (which tracked frames get a pre-rendered
overlay).

### What these tests deliberately do not cover

A JVM unit test cannot exercise anything that needs a real Android framework or
native library. The following are **not** covered and still need a device or
emulator:

- `RfDetrDiscDetector` end to end — needs `MediaMetadataRetriever`, ONNX
  Runtime's native library, and the downloaded model. Its re-entrancy guard and
  cancellation are covered by inspection only.
- `HybridDiscTracker.refine()` end to end — same reasons.
- `PostureAnalyzer.analyze()` — needs ML Kit pose detection.
- Every Compose screen, and the navigation graph wiring them together.
- `FlightVideoExporter` — needs Media3 `Transformer` and a real encoder.
- `EncryptedSharedPreferences` reads and writes, which fall back to an
  in-memory store when the keystore is unavailable.
- Training uploads against a real server.

### TODO: walk the app on a device

The Kotlin client has never been run. Assemble a debug APK and go through each
feature once, watching for the things a unit test cannot see: permission
prompts, video pickers returning a content URI the app has to copy, playback
seeking landing on the frame the analysis measured, and state surviving a
rotation or a trip through the background.

### TODO: verify the on-device Roboflow Workflow on a real video

Auto-detect runs the Workflow's RF-DETR Small model with ONNX Runtime and
tracks it with the OC-SORT port (see "The on-device disc model" in
`README.md`). The `:core` suite checks the preprocessing, decoding, and
tracker against outputs of Roboflow's own Python libraries, but **nothing here
has run the model through ONNX Runtime on a phone.**

**Before release, fetch the model, build, and confirm on a device:**
- The load log reports the model's inputs and outputs (`dets` and `labels`)
  and the first run finds the disc.
- The flight path matches what the hosted Workflow drew on the same clip.
  Frames are decoded at 30 fps, and Android's decoder may differ slightly from
  the server's, so expect close but not identical boxes.
- **Timing.** Measure real ms/frame for RF-DETR Small at 512x512 on the CPU. A
  trimmed clip is up to 300 frames, so a slow phone may take minutes.
- **Memory.** The weights are about 114 MB, mapped from the APK; check that a
  low-memory phone doesn't kill the app while the session loads.
- Frame extraction asks `MediaMetadataRetriever` for `OPTION_CLOSEST`, not the
  cheaper `OPTION_CLOSEST_SYNC`, so a frame should come back at the requested
  timestamp rather than at the nearest keyframe. Confirm that on a clip with
  sparse keyframes, where snapping would show as an overlay lagging the disc.

Detection runs on a background dispatcher, but a long clip still ties the app
to the foreground for the whole pass. Whether that needs a foreground service
or a `WorkManager` job depends on the measured per-frame cost, so decide it
from device numbers rather than in advance.

### TODO: verify the Full Auto flight-tracking flow on a device

`WorkflowDiscTracker` and the Auto-detect entry point are covered by host tests
only at the pure-function level — the quality heuristic, seed-point sampling,
frame-index maths, and the frame timestamps to sample. Everything that touches
real frames still needs a device.

**Run these with a real throw video:**

- **Trim alignment — the important one.** Mark a keyframe on a visually
  distinctive frame, then run Auto-detect and confirm the overlay lands on the
  same object at the same frame. Do it once with no trim and once with a
  non-zero trim start. Before this change, extraction always started at the
  head of the file while keyframes were counted from the trim start, so a
  trimmed clip silently paired every position with the wrong image. Re-run the
  same check on **Auto-Refine**, which had the identical bug.
- **Progress and cancel.** The bar advances smoothly (progress now notifies
  every frame, not every tenth) with real per-frame status. Cancel stops the
  run at the next frame and changes nothing. Then start a second run
  immediately: if the lock leaked, it surfaces as the `IllegalStateException`
  from `detectFrames`.
- **Quality banner.** A clean clip raises no banner. A clip where the disc
  leaves frame early raises `lowCoverage`. Thresholds live in
  `DetectionQualityThresholds` and are first-pass guesses — retune them from
  what you see here.
- **Correction path.** Edit points seeds keyframes from real detections only
  (never interpolated fill), world anchors survive the transition, and
  Auto-Refine re-runs on the result. Re-tapping a seeded point replaces it and
  clears its `derived` flag, so it becomes eligible for training collection
  again.
- **Fresh install.** Uninstall, install, and go straight to Auto-detect without
  visiting Training Settings first. In the Flutter client nothing loaded the
  model on a normal run, so the hybrid tracker silently skipped the detector
  and refined against colour blobs; confirm the load happens and
  `HybridDiscTracker.usedDetectorModel` is true.
- **Training-data offset.** With sample collection opted in and a trimmed clip,
  confirm the stored full-frame image matches the marked moment. Samples used
  to be extracted at an absolute timestamp computed from a trim-relative frame
  index, which mislabels every sample from a trimmed video.
