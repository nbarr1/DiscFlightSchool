# Testing

## Running the suites

```bash
# Server (no Docker, no ultralytics/torch needed)
python -m pip install -r server/requirements-test.txt
APP_API_KEY=test-key ./scripts/test_server.sh

# Flutter
./scripts/test_flutter.sh          # pub get + analyze + test
```

CI runs both on every pull request (`.github/workflows/server-tests.yml`,
`flutter-tests.yml`) plus a dependency audit (`dependency-audit.yml`).

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

## Flutter coverage

| File | Covers |
|---|---|
| `angle_calculator_test.dart` | 2-D/3-D joint angles, X-factor sign and magnitude, Catmull-Rom control-point interpolation, anchor filling |
| `scoring_service_test.dart` | round persistence (including the undo/re-enter duplicate-save regression), corrupt-store resilience, statistics |
| `posture_analysis_service_test.dart` | lead/trail knee labelling per throw type, physiological-limit clamping vs dropping, pro deviation scoring |
| `knowledge_base_service_test.dart` | Anthropic request shape and response parsing, including thinking-block handling, refusals, truncation, and transport errors |
| `disc_detection_service_test.dart` | model-output parsing for both YOLO tensor layouts, spatial-coherence filtering, smoothing, gap interpolation, frame-index alignment |
| `training_data_service_test.dart` | server URL allow-listing, same-origin checks, API-key clearing on origin change, YOLO label/server-validator agreement |
| `data_contracts_test.dart`, `disc_tracker_test.dart`, `widget_test.dart` | pre-existing model round-trips, spline tracker, app startup routing |

### What these tests deliberately do not cover

Host-side `flutter test` cannot exercise anything that needs a platform channel
or native library. The following are **not** covered and still need a device or
emulator:

- `DiscDetectionService.processVideo()` end to end — needs `path_provider`,
  `ffmpeg_kit_flutter_new`, and the TFLite native library (including the GPU
  delegate path). Its re-entrancy guard, lock release, and temp-directory
  cleanup are covered by inspection only.
- `HybridDetectionService.detect()` end to end — same reasons.
- `PostureAnalysisService.analyzeForm()` — needs ML Kit pose detection.
- Secure-storage reads and writes. In unit tests
  `flutter_secure_storage` throws `MissingPluginException`, which the services
  catch; the tests therefore exercise the in-memory key path, not persistence.
- Model download and upload against a real server.

### TODO: verify track-by-detection on a real video

`DiscDetectionService` was rewritten around a track-by-detection state machine
(full-frame discovery → windowed tracking with velocity prediction → fall back
to discovery after a short occlusion streak — see `detectInWindow`,
`_DiscTrack`, and the loop in `processVideo`), plus a single-pass FFmpeg frame
extraction and an optional GPU delegate.

Note the bundled asset is still the **YOLOv8n@320** export, not YOLO11 — see
the client facts in `README.md`. The checks below apply either way, but the
first one gates swapping in the YOLO11n@640 model.
`flutter analyze` and `flutter test` are clean and cover every pure function
in isolation (candidate selection, coherence filtering, smoothing,
interpolation), but **nothing here exercises the state machine against real
frames, the FFmpeg extraction command, or the GPU delegate — all of that
needs a device and a real throw video.**

**Before release, run a full tracking pass on a device and confirm:**
- The FFmpeg extraction command (`fps` + `scale` filter, single pass) actually
  produces the expected frame sequence — the escaped-comma filter syntax
  (`scale=min(640\,iw):-2`) was verified by inspection against FFmpegKit's
  tokenizer, not by running it.
- Discovery mode finds the disc leaving the hand/early flight, tracking mode
  follows it through a full flight without losing the lock, and a lock lost to
  occlusion (e.g. the disc crossing behind the thrower) is reacquired via
  discovery rather than tracking a false candidate.
- The resulting trajectory overlay is at least as accurate as the previous
  (YOLOv8, full-frame-every-frame, 320-input) build on the same clip.
- **Model swap.** After dropping in the YOLO11n export, the load log reports
  `input [1, 640, 640, 3]` / `output [1, 5, 8400]` and raises no geometry
  warning, and detection still works on a clip that worked before. This is the
  acceptance gate for the upgrade.
- **Timing at 640.** Measure real ms/frame. Per-frame cost scales with input
  area, so a 640 model is roughly 4× the 320 export. If a trimmed clip still
  takes minutes after the `getBytes` preprocessing change and the trim-derived
  frame budget, the isolate migration below stops being optional.
- The GPU delegate actually engages on a real Android/iOS device (check the
  `debugPrint` in `_loadModelImpl`) and inference doesn't silently fall back to
  CPU-only in a way that regresses processing time.
- A second `processVideo()` call after a model reload still produces output —
  the input and output buffers are invalidated and reallocated to the new
  model's geometry on reload, and that path is untested against the real
  interpreter.

Moving inference off the UI isolate entirely (via `IsolateInterpreter`) remains
outstanding; it needs device testing to validate, so it was not attempted
blind.

### TODO: verify the Full Auto flight-tracking flow on a device

`AutoDiscTracker` and the Auto-detect entry point are covered by host tests
only at the pure-function level — the quality heuristic, seed-point sampling,
frame-index maths, and the FFmpeg command string. Everything that touches real
frames still needs a device.

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
  visiting Training Settings first. Previously nothing loaded the model on a
  normal run, so `HybridDetectionService` silently skipped YOLO entirely and
  refined against colour blobs; confirm the load now happens and
  `usedDetectorModel` is true.
- **Training-data offset.** With sample collection opted in and a trimmed clip,
  confirm the stored full-frame image matches the marked moment. Samples used
  to be extracted at an absolute timestamp computed from a trim-relative frame
  index, which mislabels every sample from a trimmed video.
