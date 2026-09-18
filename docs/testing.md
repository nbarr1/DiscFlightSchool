# Testing

## Roboflow flight path

Automated backend and Android tests use fake HTTP/WebRTC responses and never
spend inference credits. Run the server suite with `APP_API_KEY=test-key
./scripts/test_server.sh` and Android tests with `./scripts/test_android.sh`.

For the opt-in real Workflow check, install `server/requirements.txt`, set
`ROBOFLOW_API_KEY` and `ROBOFLOW_TEST_VIDEO` to a short throw, then run
`python scripts/test_roboflow_integration.py`. The same check runs in CI as
`Roboflow Workflow Smoke Test`, which is manual dispatch only because each run
spends inference credits: it reads the `ROBOFLOW_API_KEY` repository secret,
takes an optional `video_url` input (without one it generates a synthetic clip
that exercises the connection but detects nothing), and uploads the annotated
MP4 as an artifact. Confirm the generated MP4 opens,
then configure the same backend in Android Training Settings and verify on a
device: pick and record, preview, process, progress/indeterminate processing,
playback, sharing, retry, cancellation, and duplicate-tap prevention. Do not
mark the mobile integration verified until the annotated result plays there.

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
| `KnowledgeSearchTest.kt` | local keyword search plus the Anthropic request shape and response parsing, including thinking-block handling, refusals, truncation, and transport errors |
| `DiscDetectionTest.kt` | model-output parsing for both YOLO tensor layouts, input-layout detection, both preprocessing write orders, spatial-coherence filtering, smoothing, gap interpolation, frame-index alignment |
| `DetectionQualityTest.kt` | the coverage/interpolation/confidence heuristic, its thresholds against the user's sensitivity setting, and seed-point sampling |
| `TrackerTest.kt` | the spline tracker, the frame budget derived from a trimmed span, and frame-index maths |
| `WorldAnchorTest.kt` | the similarity transform that keeps a flight path pinned to the scene while the camera pans and zooms |
| `ServerUriTest.kt` | server URL allow-listing, same-origin checks, endpoint construction |
| `RouletteTest.kt` | disc/power/shape generation, incompatible-combination filtering, difficulty weighting |
| `DataContractsTest.kt` | the persisted formats — landmark keys, ISO timestamps, legacy fields — that an upgrading install still has to read |

`:app`'s own unit tests cover the helpers that are Android-free but live in the
Android module: `FormattingTest.kt` (scorecard and history readouts),
`FrameIndexTest.kt` and `FrameForFractionTest.kt` (timestamp-to-frame maths),
and `FlightVideoExporterTest.kt` (which tracked frames get a pre-rendered
overlay).

### What these tests deliberately do not cover

A JVM unit test cannot exercise anything that needs a real Android framework or
native library. The following are **not** covered and still need a device or
emulator:

- `DiscDetector.processVideo()` end to end — needs `MediaMetadataRetriever` and
  the TensorFlow Lite native library (including the GPU delegate path). Its
  re-entrancy guard, cancellation, and buffer reallocation on model reload are
  covered by inspection only.
- `HybridDiscTracker.refine()` end to end — same reasons.
- `PostureAnalyzer.analyze()` — needs ML Kit pose detection.
- Every Compose screen, and the navigation graph wiring them together.
- `FlightVideoExporter` — needs Media3 `Transformer` and a real encoder.
- `EncryptedSharedPreferences` reads and writes, which fall back to an
  in-memory store when the keystore is unavailable.
- Model download and upload against a real server.

### TODO: walk the app on a device

The Kotlin client has never been run. Assemble a debug APK and go through each
feature once, watching for the things a unit test cannot see: permission
prompts, video pickers returning a content URI the app has to copy, playback
seeking landing on the frame the analysis measured, and state surviving a
rotation or a trip through the background.

### TODO: verify track-by-detection on a real video

`DiscDetector` was built around a track-by-detection state machine
(full-frame discovery → windowed tracking with velocity prediction → fall back
to discovery after a short occlusion streak — see `detectInWindow`, `DiscTrack`,
and the loop in `processVideo`), plus `MediaMetadataRetriever` frame extraction
and an optional GPU delegate.

The bundled asset is now a genuine **YOLO11n@640** export — see the client
facts in `README.md`. It arrived as `format="litert"`/`quantize="w8a32"`
output from Ultralytics' current exporter, which (as of Ultralytics 8.4.83,
when the standalone `tflite` format was removed) produces **NCHW**
(`[1,3,640,640]`) rather than the NHWC layout the app originally assumed —
`YoloOutput.detectInputLayout` and both `YoloPreprocessor` write paths handle
this, covered at the pure-function level, but **none of it has run against a
real interpreter yet.**
The `:core` suite covers every pure function in isolation (candidate
selection, coherence filtering, smoothing, interpolation, the NHWC/NCHW layout
detection, and both preprocessing write patterns), but **nothing here
exercises the state machine against real frames, frame extraction, or the GPU
delegate — all of that needs a device and a real throw video.**

**Before release, run a full tracking pass on a device and confirm:**
- Frame extraction produces the expected sequence. `FrameExtractor` asks
  `MediaMetadataRetriever` for `OPTION_CLOSEST`, not the cheaper
  `OPTION_CLOSEST_SYNC`, so a frame should come back at the requested
  timestamp rather than at the nearest keyframe — confirm that on a clip with
  sparse keyframes, where snapping would be visible as an overlay lagging the
  disc.
- Discovery mode finds the disc leaving the hand/early flight, tracking mode
  follows it through a full flight without losing the lock, and a lock lost to
  occlusion (e.g. the disc crossing behind the thrower) is reacquired via
  discovery rather than tracking a false candidate.
- The resulting trajectory overlay is at least as accurate as the previous
  (YOLOv8, full-frame-every-frame, 320-input) build on the same clip.
- **Model swap.** The load log reports `input [1, 3, 640, 640] (NCHW)` /
  `output [1, 5, 8400]` and raises no geometry warning, and detection still
  works on a clip that worked before. This is the acceptance gate for the
  upgrade — it's the one thing the pure-function tests genuinely cannot
  cover, since it depends on the real interpreter accepting the buffer shape
  `YoloPreprocessor` builds.
- **Timing at 640.** Measure real ms/frame. Per-frame cost scales with input
  area, so a 640 model is roughly 4× the 320 export. If a trimmed clip still
  takes minutes with the reused direct buffers and the trim-derived frame
  budget, the background-execution question below stops being optional.
- The GPU delegate actually engages on a real device (check the load log) and
  inference doesn't silently fall back to CPU-only in a way that regresses
  processing time.
- A second `processVideo()` call after a model reload still produces output —
  the input and output buffers are invalidated and reallocated to the new
  model's geometry on reload, and that path is untested against the real
  interpreter.

Detection runs on a background dispatcher, but a long clip still ties the app
to the foreground for the whole pass. Whether that needs a foreground service
or a `WorkManager` job depends on the measured per-frame cost, so decide it
from device numbers rather than in advance.

### TODO: verify the Full Auto flight-tracking flow on a device

`AutoDiscTracker` and the Auto-detect entry point are covered by host tests
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
  immediately: if the lock leaked, it surfaces as the `StateError` from
  `processVideo`.
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
  model on a normal run, so the hybrid tracker silently skipped YOLO entirely
  and refined against colour blobs; confirm the load happens and
  `HybridDiscTracker.usedDetectorModel` is true.
- **Training-data offset.** With sample collection opted in and a trimmed clip,
  confirm the stored full-frame image matches the marked moment. Samples used
  to be extracted at an absolute timestamp computed from a trim-relative frame
  index, which mislabels every sample from a trimmed video.
