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
  `video_thumbnail`, and the TFLite native library. Its re-entrancy guard,
  lock release, and temp-directory cleanup are covered by inspection only.
- `HybridDetectionService.detect()` end to end — same reasons.
- `PostureAnalysisService.analyzeForm()` — needs ML Kit pose detection.
- Secure-storage reads and writes. In unit tests
  `flutter_secure_storage` throws `MissingPluginException`, which the services
  catch; the tests therefore exercise the in-memory key path, not persistence.
- Model download and upload against a real server.

### Known unverified change

The disc-detection inference path was changed to reuse its input and output
buffers across frames instead of reallocating ~350k boxed doubles per frame.
This is a large allocation win and was reviewed by inspection, but it has not
been run against the real TFLite interpreter in this environment.

**Before release, run a tracking pass on a device and confirm:** detections
still appear, the trajectory overlay matches the previous build on the same
clip, and a second `processVideo()` call after a model reload still produces
output (the output buffer is invalidated on reload — that path is untested).

Moving inference off the UI isolate entirely (via `IsolateInterpreter`) remains
outstanding; it needs device testing to validate, so it was not attempted
blind.
