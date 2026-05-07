# Phase 2 Synthesis — DiscFlightSchool

This document converts the Phase 1 reconnaissance into a rebuild baseline. It is intentionally limited to Phase 2: system summary, functional specification, data contract specification, integration points, and quality baseline. It does **not** make Phase 3 architecture choices or start Phase 4 implementation.

## System Summary

DiscFlightSchool is a disc golf training product for players who want practical feedback on two high-value skills: throwing form and disc flight execution. The Flutter app runs most core workflows locally: it lets users record or import videos, track a disc through flight frames with an on-device TFLite model, analyze throw posture with on-device pose detection, compare biomechanics against professional baseline data, browse research-backed technique content, and play Disc Roulette practice rounds.

The companion FastAPI server supports the app's opt-in model-improvement loop. Authenticated users/operators upload manually corrected disc detection samples, export YOLO-format training data, trigger YOLOv8 retraining, and distribute the latest `.tflite` detector model back to clients. The system primarily serves individual disc golf players, coaches reviewing form, and an operator maintaining the detection model and baseline content.

## Functional Specification

### App Startup and Navigation

1. A first-time user can launch the app and see onboarding before the home screen.
2. A returning user can launch directly to the home screen after `onboarding_complete` is stored locally.
3. A user can navigate from home into Flight Tracker, Form Coach, Disc Roulette, Knowledge Base, Gallery, and Training Settings modules.
4. The app provides a consistent dark theme and safe-area handling across screens.

### Flight Tracker

5. A user can import or record a video for disc flight tracking.
6. A user can play selected videos in the app.
7. The system can extract representative frames from a video for analysis.
8. The system can load a bundled TFLite disc detector from app assets.
9. The system can load a downloaded replacement TFLite detector from the app documents directory.
10. The system can preprocess extracted frames to the detector input size and run TFLite inference.
11. The system can parse supported detector output tensor layouts into normalized disc bounding boxes.
12. The system can apply a user-configurable confidence threshold to detections.
13. The system can persist the detection confidence threshold locally.
14. The system can filter detection chains for spatial coherence so impossible frame-to-frame jumps are discarded.
15. The system can smooth detection paths over a short window.
16. The system can interpolate short gaps between detections.
17. A user can view an overlay of the detected disc path on top of video frames.
18. A user can use manual tracking when automated detection is insufficient.
19. A user can create keyframe annotations by placing/correcting a disc bounding box.
20. The system can convert keyframe annotations into normalized YOLO class-0 labels.
21. A user can save local training samples derived from annotated frames.
22. A user can review local saved training samples and upload pending samples if training server settings are configured.
23. The system can mark successfully uploaded samples as uploaded.
24. The system can export local training samples as JSON for manual transfer or debugging.

### Training Server Settings and Model Updates

25. A user can configure the training server base URL.
26. A user can configure the private training API key.
27. The app stores the server URL in SharedPreferences.
28. The app stores the training API key in secure storage and removes legacy/plain entries when migrated.
29. A user can test training server connectivity through `/health`.
30. A user can check whether a newer detector model is available from `/api/model/version`.
31. The app can compare the downloaded/local model version with the server version.
32. The app can download the server-provided model URL.
33. The app can verify the downloaded model's SHA-256 digest before replacing the local model.
34. The app can persist the active downloaded model version.
35. The app can reload the detector after a successful verified model update.
36. The app must reject model updates with a digest mismatch and preserve the existing detector.

### Form Coach

37. A user can record or import a throw video for form analysis.
38. A user can trim a selected form video before analysis.
39. A user can choose throw type: backhand (`BH`) or forehand (`FH`).
40. A user can select professional reference data/player where available.
41. A user can select phase frames for backhand phases: Reach Back, Power Pocket, Release, Follow Through.
42. A user can select phase frames for forehand phases: Wind Up, Power Pocket, Release, Follow Through.
43. The system can run on-device pose detection against video frames.
44. The system can extract 2D landmarks, optional depth values, and landmark confidence values.
45. The system can calculate elbow flexion, shoulder flexion, lead/trail knee flexion, trunk lateral tilt, X-factor/hip-shoulder separation, and off-arm metrics where landmarks are available.
46. The system can normalize/mirror angle semantics for left-handed comparisons when needed.
47. The system can compare user phase angles against professional baseline means and standard deviations.
48. The system can compute an overall form score.
49. The system can produce coaching suggestions when user angles deviate from baseline ranges.
50. The system can surface baseline quality warnings for known occlusion/camera-angle issues.
51. A user can view phase-by-phase comparison details.
52. A user can view skeleton overlays on analyzed frames.
53. A user can correct detected skeleton landmarks manually.
54. A user can move individual joints during correction.
55. A user can shift the full skeleton during correction.
56. A user can use guided sequential joint placement during correction.
57. The system can interpolate corrected landmarks across affected frames.
58. The system can recalculate angles after corrections.
59. A user can save form-analysis history locally.
60. A user can view historical form sessions with date, score, throw type, selected pro, frame count, and average angles.
61. A user can clear form-history records.
62. A user can submit verification feedback to a local JSON feedback log.

### Knowledge Base and AI Search

63. A user can browse knowledge-base categories.
64. A user can view articles within a category.
65. A user can open an article detail page with answer text, key findings, and source study references.
66. A user can search local knowledge-base content.
67. Coaching suggestions can link users to relevant knowledge-base articles.
68. A user can configure an Anthropic API key for optional AI Q&A.
69. The app stores the Anthropic API key in secure storage and migrates/removes legacy SharedPreferences storage.
70. A user can ask natural-language questions against bounded knowledge-base context when an Anthropic key is present.
71. The system must handle missing Anthropic keys by disabling or refusing AI search gracefully.
72. The system must keep offline knowledge-base browsing usable without a network connection or AI key.

### Disc Roulette

73. A user can spin/generate a random Disc Roulette challenge.
74. The system can generate shot-type constraints: hyzer, anhyzer, flat, roller, tomahawk, thumber, grenade, scoober.
75. The system can generate power/modifier constraints: full power, half power, quarter power, overhand, standstill, run-up, X-step.
76. The system can generate hindrance constraints: none, off-hand, eyes closed, backwards, one leg, sitting, kneeling, spin first.
77. The system can generate putting-style constraints: kneeling, straddle, turbo, spin, push, spush.
78. The system can optionally include a disc name in a roulette result.
79. The system can timestamp generated roulette results.
80. The app can persist a bounded history of recent roulette spins.
81. A user can start a scored Disc Roulette round.
82. A user can configure players for a scored round.
83. A user can configure course pars or use default 18-hole par-3 course pars.
84. A user can record hole scores per player.
85. A user can record multiple challenge throws per hole.
86. The system can compute raw strokes per player.
87. The system can compute raw score-to-par per player.
88. The system can compute challenge-weighted scores when weighting is enabled.
89. The system can determine whether all players have completed all holes.
90. A user can view a scorecard.
91. The system can read legacy hole-score JSON that used a single `challenge` field instead of a `throws` list.
92. A user can review saved roulette/scored-round history.

### Knowledge/Asset-Backed Analysis Screens

93. A user can view bundled sample flight path data from `output_coordinates.json`.
94. A user can view bundled sample analysis result values from `analysis_results.json`.
95. The app can load and parse the professional baseline database from app assets.
96. The app can load and parse the knowledge-base database from app assets.
97. The app can display bundled SVG/image/icon assets where referenced by UI.

### FastAPI Training and Model Server

98. An operator can start the server only when `APP_API_KEY` is set.
99. The server can accept authenticated multipart training-sample uploads.
100. The server validates `sample_id` format before writing files.
101. The server validates YOLO label shape before writing labels.
102. The server validates image dimensions are positive.
103. The server normalizes unsupported upload file extensions to `.jpg`.
104. The server validates JPEG/PNG magic bytes before accepting uploaded images.
105. The server enforces `MAX_UPLOAD_BYTES` per uploaded image.
106. The server stores full images, crop images, and labels in YOLO-compatible train directories.
107. The server updates upload stats after successful sample storage.
108. The server can return dataset sample/label statistics.
109. The server can export images, labels, and dataset YAML as a ZIP file to authenticated callers.
110. The server can report the latest model version, hash, and download URL.
111. The server can serve the latest `.tflite` model file.
112. The server can return a graceful `version:"none"` response when no model exists.
113. The server can return `404` when model download is requested and no model exists.
114. The server can start a YOLOv8 training job in a background thread when authenticated and enough data exists.
115. The server refuses training start when another training job is running.
116. The server refuses training start when fewer than 10 full-image samples exist.
117. The server records in-memory training status including running state, last run time, and result.
118. The server exposes a health endpoint.
119. The server exposes a root metadata endpoint listing supported endpoints.
120. The server supports configurable CORS origins for browser clients.

### Prototype Python Bridge

121. A local Python bridge can expose a health check for Flutter's `PythonBridgeService`.
122. A local Python bridge can receive uploaded videos for flight tracking.
123. A local Python bridge can receive uploaded videos for form analysis.
124. Prototype flight tracking can use OpenCV/Numpy heuristics for disc detection and trajectory analysis.
125. Prototype form analysis can use MediaPipe/Numpy pose/form comparison helpers.
126. Because this bridge is not the primary production path, a rebuild may preserve it as a compatibility/prototype adapter or explicitly retire it in the Phase 5 delta report.

## Data Contract Specification

### HTTP: `POST /api/training/upload`

- Protocol: HTTPS/HTTP multipart form-data.
- Auth: `X-App-Key` header; exact string comparison to `APP_API_KEY`.
- Required form fields:
  - `sample_id`: string, 1–80 characters, regex `^[A-Za-z0-9_-]{1,80}$`, non-null.
  - `label`: string, exactly one non-empty YOLO row, regex-compatible with `0 center_x center_y width height`, non-null.
  - `image_width`: integer, `> 0`, non-null.
  - `image_height`: integer, `> 0`, non-null.
  - `full_image`: file, non-empty JPEG/PNG by signature, max `MAX_UPLOAD_BYTES`, non-null.
  - `crop_image`: file, non-empty JPEG/PNG by signature, max `MAX_UPLOAD_BYTES`, non-null.
- Optional form fields:
  - `app_version`: string, defaults to `unknown`.
- Success response: HTTP `200`, JSON object `{ "status": "ok", "sample_id": string, "message": "Sample received" }`.
- Error responses:
  - HTTP `403`, `{ "error": "Invalid or missing API key" }`.
  - HTTP `400`, `{ "error": string }` for invalid id, invalid label, invalid dimensions, upload too large, or bad image signature.

### HTTP: Model and Training Server Responses

- `GET /api/model/version`: HTTP `200`, JSON object `{ "version": string, "sha256": string, "url": string }`; no-model sentinel is `{ "version": "none", "sha256": "", "url": "" }`.
- `GET /api/model/download`: success is binary `.tflite` file response; no model returns HTTP `404`, `{ "error": "No model available" }`.
- `GET /api/training/stats`: JSON object containing at least `total_samples`, `last_upload`, `image_count`, `label_count`.
- `GET /api/training/export`: authenticated ZIP file response containing `images/`, `labels/`, and `dataset.yaml`; invalid auth returns HTTP `403`.
- `POST /api/training/start`: authenticated JSON responses:
  - Started: `{ "status": "started", "message": string }`.
  - Already running: HTTP `409`, `{ "status": "already_running", "message": "Training is already in progress" }`.
  - Insufficient data: HTTP `400`, `{ "status": "insufficient_data", "count": integer, "minimum": 10 }`.
- `GET /api/training/status`: JSON object `{ "running": boolean, "last_run": string|null, "result": object|string|null }`.
- `GET /health`: `{ "status": "ok" }`.
- `GET /`: `{ "service": "Disc Flight School Training Server", "endpoints": string[] }`.

### Stored Server Files

- Full image path: `dataset/images/train/{sample_id}_full.{jpg|jpeg|png}`.
- Crop image path: `dataset/images/train/{sample_id}_crop.{jpg|jpeg|png}`.
- Label path: `dataset/labels/train/{sample_id}.txt`.
- Label content: one line, `0 {center_x} {center_y} {width} {height}`, where numeric fields are normalized decimals in `[0,1]`.
- Dataset config path: `dataset/dataset.yaml` with YOLO keys `path`, `train`, `val`, and `names: {0: disc}`.
- Stats path: `stats.json`, JSON object `{ "total_samples": integer, "last_upload": iso_datetime_string|null }`.
- Model path: `models/*.tflite`; version is the latest modified model stem; digest is SHA-256 of bytes.

### Flutter Model: `TrainingSample`

- `id`: string, non-null.
- `imagePath`: string path to full image, non-null.
- `cropPath`: string path to crop image, non-null.
- `centerX`, `centerY`, `boxWidth`, `boxHeight`: double, normalized YOLO coordinates, non-null.
- `frameIndex`: integer, non-null.
- `imageWidth`, `imageHeight`: integer pixels, non-null.
- `createdAt`: ISO-8601 datetime, non-null.
- `uploaded`: boolean, non-null, default `false` when absent in legacy JSON.
- Derived `toYoloLabel()`: `0` plus all four normalized values fixed to six decimal places.

### Flutter Model: Disc and Flight Data

- `Disc`: `id` string, `name` string, `manufacturer` string, `type` string, `speed` double, `glide` double, `turn` double, `fade` double, `imageUrl` nullable string.
- `FlightData`: `id` string, `distance` double, `maxHeight` double, `flightTime` double, `speed` double, `launchAngle` double, `points` list of 2D offsets, `videoPath` nullable string, `discId` nullable string, `recordedAt` ISO-8601 datetime.

### Flutter Model: Form Analysis

- `FormFrame`:
  - `timestamp`: duration, non-null.
  - `angles`: map string to double, non-null.
  - `keyPoints`: map landmark name string to 2D offset, non-null.
  - `landmarkZ`: map landmark name string to double depth estimate, non-null, may be empty.
  - `landmarkConf`: map landmark name string to double confidence, non-null, may be empty.
  - `imageWidth`, `imageHeight`: nullable double.
- `FormAnalysis`:
  - `id`: string, non-null.
  - `date`: ISO-8601 datetime, non-null.
  - `videoPath`: string path, non-null.
  - `frames`: list of `FormFrame`, non-null.
  - `score`: double, non-null.
- `ProFormData`: `playerName` string, `analysis` `FormAnalysis`, `description` string.
- `FormSessionRecord`: `id` string, `date` ISO-8601 datetime, `score` double, `throwType` string (`BH` or `FH`), `proPlayer` nullable string, `frameCount` integer, `avgAngles` map string to double.

### Flutter Model: Professional Baseline Database

- Top-level object:
  - `metadata`: object with versioning/source/landmark/angle/quality metadata.
  - `players`: object keyed by player name.
  - `baseline_summary`: object keyed by throw type (`BH`, `FH`).
- Player object:
  - `pdga_rating`: integer.
  - `throws`: object keyed by `BH` and/or `FH`.
  - `anthropometry`: object when present.
- Throw object:
  - `clips`: list/object of source clip metadata.
  - `phases`: object keyed by phase ids.
- Backhand phases: `reach_back`, `power_pocket`, `release`, `follow_through`.
- Forehand phases: `wind_up`, `power_pocket`, `release`, `follow_through`.
- Phase angle fields include nullable numeric values such as `elbow_flexion_deg`, `shoulder_flexion_deg`, `lead_knee_flexion_deg`, `trail_knee_flexion_deg`, `trunk_lateral_tilt_deg`, `x_factor_deg`, off-arm measurements, confidence, visibility notes, reference-frame metadata, depth estimates, landmark version/count.
- Baseline summary stats are keyed by phase and angle and include numeric `mean`, `sd`, `min`, `max`, and integer `n` where available.

### Flutter Model: Knowledge Base

- Top-level object: `{ "categories": KBCategory[], "studies": KBStudy[], "articles": KBArticle[] }`.
- `KBCategory`: `id` string, `name` string, `iconName` string, `colorValue` integer ARGB, `description` string.
- `KBStudy`: `id` string, `title` string, `authors` string, `year` integer, `filename` string, `summary` string.
- `KBArticle`: `id` string, `category` string referencing `KBCategory.id`, `type` string, `question` string, `answer` string, `keyFindings` string list, `sourceIds` string list referencing `KBStudy.id`.

### Flutter Model: Roulette

- `PuttStyle`: one of `kneeling`, `straddle`, `turbo`, `spin`, `push`, `spush`.
- `ShotType`: one of `hyzer`, `anhyzer`, `flat`, `roller`, `tomahawk`, `thumber`, `grenade`, `scoober`.
- `PowerModifier`: one of `fullPower`, `halfPower`, `quarterPower`, `overhand`, `standstill`, `runUp`, `xStep`.
- `Hindrance`: one of `none`, `offHand`, `eyesClosed`, `backwards`, `oneLeg`, `sitting`, `kneeling`, `spinFirst`.
- `RouletteResult`: `shotType` enum, `discName` nullable string, `powerModifier` enum, `hindrance` enum, `puttStyle` nullable enum, `timestamp` ISO-8601 datetime.
- `GameSession`: `id` string, `players` string list, `results` list of `RouletteResult`, `startedAt` ISO-8601 datetime.
- `ThrowRecord`: `throwNumber` integer, `challenge` `RouletteResult`, `isPutt` boolean.
- `HoleScore`: `holeNumber` integer, `par` integer, `strokes` integer, `throws` list of `ThrowRecord`, `playerName` string; legacy input may contain a single `challenge` instead of `throws`.
- `ScoredRound`: `id` string, `playerNames` string list, `startedAt` ISO-8601 datetime, `completedAt` nullable ISO-8601 datetime, `coursePars` integer list, `scores` `HoleScore` list, `useWeighting` boolean default `true`.

### Local Persistence Keys and Files

- `onboarding_complete`: SharedPreferences boolean.
- `disc_confidence_threshold`: SharedPreferences double.
- `form_session_history`: SharedPreferences string list of encoded `FormSessionRecord` objects.
- Roulette history keys: SharedPreferences JSON for recent spins and scored rounds.
- Training server URL key: SharedPreferences string.
- Training API key: secure storage string; legacy SharedPreferences value may be migrated and removed.
- Anthropic API key: secure storage string; legacy SharedPreferences value may be migrated and removed.
- Downloaded model path: application documents `training_data/models/disc_detector.tflite`.
- Local sample export: JSON array of `TrainingSample` objects.
- Local feedback file: application documents `verification_feedback.json`, JSON array of feedback maps.

## Integration Points

1. **Flutter platform APIs**
   - Protocol: Flutter plugin method channels/native platform APIs.
   - Auth: platform app sandbox permissions, media permissions where required.
   - Used for: media picking, file access, gallery save, secure storage, SharedPreferences, video playback, thumbnails, ML Kit pose detection, TFLite inference.

2. **Training/model server**
   - Protocol: HTTP/HTTPS JSON, multipart form-data, and binary file download.
   - Auth: `X-App-Key` header for upload/export/training-start; no auth for health/stats/status/model version/download in current contract.
   - Used for: upload training samples, check model version, download verified model, health checks, dataset export, operator training start/status.

3. **Anthropic Messages API**
   - Protocol: HTTPS JSON.
   - Auth: user-provided Anthropic API key stored in secure storage and sent as provider-required API auth headers by the app.
   - Used for: optional AI knowledge-base Q&A. Offline browsing/search does not depend on this integration.

4. **Local prototype Flask bridge**
   - Protocol: local HTTP multipart upload under `http://localhost:5000/api`.
   - Auth: none in prototype code.
   - Used for: optional/prototype video flight tracking and form analysis endpoints consumed by `PythonBridgeService`.

5. **YOLOv8/Ultralytics training CLI**
   - Protocol: server-side subprocess invocation.
   - Auth: indirectly protected by `/api/training/start` `X-App-Key`.
   - Used for: training a detector from accumulated YOLO samples and exporting a `.tflite` model.

6. **Bundled research and model assets**
   - Protocol: Flutter asset bundle file reads.
   - Auth: none.
   - Used for: pro baseline comparison, knowledge-base content, sample flight/analysis screens, bundled detector fallback, app UI assets.

## Quality Baseline

### Performance

- App workflows should remain mobile-friendly and primarily on-device; Form Coach and Flight Tracker must not require a network round trip for core analysis.
- Flight tracking should process sampled frames without unbounded memory growth; temporary extracted frames should be cleaned up after processing.
- Detection post-processing must keep path smoothing/interpolation bounded by small windows and short gaps.
- Server upload handling must stream image bytes and enforce `MAX_UPLOAD_BYTES` rather than buffering unlimited request bodies.
- Model update verification should be linear in model size and must not block replacement until SHA-256 validation succeeds.

### Reliability

- The app must preserve existing local data formats or migrate them safely, including legacy roulette `challenge` hole-score JSON and legacy secret storage locations.
- The app must continue functioning offline for bundled Form Coach baselines, Disc Roulette, local history, and Knowledge Base browsing.
- Downloaded detector replacement must be atomic from the user's perspective: invalid downloads or hash mismatches must leave the previous usable model intact.
- Server import/startup must fail fast when `APP_API_KEY` is absent.
- Server endpoints must return explicit JSON errors for validation and auth failures.
- Training status in the original server is in-memory only; a rebuild must at minimum preserve status observability and should improve durability if Phase 3 selects persistent job state.

### Security

- No production training key or Anthropic API key may be committed or shipped as a default.
- Client-side secrets must use platform secure storage, with legacy plaintext preferences removed after migration.
- Mutating/high-risk training endpoints must require `X-App-Key` or a stronger replacement auth scheme with a compatibility plan.
- Server file writes must remain path-safe and constrained to dataset/model directories.
- Image uploads must continue to enforce type signatures, size limits, positive dimensions, and single-row YOLO label validation.
- CORS must be explicit via configuration, not permissive by default.

### Testability and Coverage Expectations

- Existing server validation behavior is covered only by direct function checks; a rebuilt system must preserve those cases and add HTTP contract tests.
- Existing Flutter tests are not meaningful for the current UI; a rebuild must add service/model tests for each persisted contract and at least smoke/golden tests for key flows.
- Each functional unit in the rebuilt system should have happy-path, error-path, and edge-case tests, especially training upload, model update hash mismatch, legacy round parsing, form baseline fallback, and offline knowledge-base loading.

### Observability

- Current baseline includes `/health`, training status, Uvicorn/Gunicorn logs, and local feedback/history files.
- A rebuild must preserve health/status visibility and should add structured request/application logs, request ids, error counters, and duration metrics without changing public behavior.

## Phase Boundary

Phase 2 is complete as a synthesis baseline. The next step is Phase 3 Architecture Decision Records; no architecture decisions or implementation changes are made in this document.
