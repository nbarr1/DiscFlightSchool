# Disc Flight School Flutter App

This directory contains the Flutter client for DiscFlightSchool. This README reflects the current source tree as audited on 2026-08-19.

## What is currently implemented

- App bootstrap in `lib/main.dart` with Provider-registered services and onboarding/home startup routing.
- Home navigation to Flight Tracker, Form Coach, Disc Roulette, Knowledge Base, Training Settings, and Flight Path Gallery.
- Flight Tracker screens and services for bundled/downloaded TFLite (YOLO11n, 640×640, dynamic-INT8/`w8a32` quantized) detection, overlays, video playback, and saved flight data. Automated detection is track-by-detection (full-frame discovery, then windowed tracking with velocity prediction); a user-seeded keyframe/spline/hybrid path remains available as a manual alternative. After trimming, the user picks "Auto-detect" (zero taps, with progress and a low-confidence warning) or "Mark manually" — see the root `README.md`'s Flight Tracker bullet for the full flow and the model's tensor layout (NCHW, not NHWC — the Ultralytics export changed this).
- Form Coach screens and services for video selection/trimming, ML Kit pose analysis, phase comparison, pose correction, feedback, and local form-history persistence.
- Disc Roulette models, random challenge generation, scored rounds, scorecards, and local history persistence.
- Knowledge Base models/screens/services using bundled JSON assets, with optional API-key-backed AI search behavior in the UI.
- Training-data collection and upload support through `TrainingDataService`, with opt-in local sample collection and secure storage for the private training API key.
- Detector model update checks/downloads from the configured server, including SHA-256 verification before replacing the local model file.
- A privacy policy (`lib/legal/privacy_policy.dart`, `lib/screens/settings/privacy_policy_screen.dart`), linked from Training Settings.

There is no repository/persistence abstraction layer — services own their storage directly (`SharedPreferences`, secure storage, or the app documents directory).

## Key project facts

- Package: `disc_golf_app`.
- Version: `1.0.0+1`.
- Dart SDK: `>=3.8.0 <4.0.0`.
- Android application ID: `com.discflightschool.app`.
- Android compile SDK: `36`.
- Android NDK: `27.0.12077973`.
- Bundled model asset: `assets/models/disc_detector.tflite`.
- Bundled data assets: `assets/data/pro_baseline_db.json` and `assets/data/knowledge_base.json`.

## Setup

```bash
cd disc_golf_app
flutter pub get
flutter run
```

## Test and analysis commands

From the repository root:

```bash
./scripts/test_flutter.sh
```

The script runs:

```bash
cd disc_golf_app
flutter pub get
flutter analyze
flutter test
```

## Build a testable Android APK

Prerequisites:

- Flutter SDK installed and on `PATH`.
- Android SDK with compile SDK 36.
- Android NDK `27.0.12077973`.
- Java 17.
- Network access or cached pub/Gradle dependencies.

Build sequence:

```bash
cd disc_golf_app
flutter doctor -v
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Expected APK path:

```text
build/app/outputs/flutter-apk/app-debug.apk
```

For a release APK, create `android/key.properties` with `keyAlias`, `keyPassword`, `storeFile`, and `storePassword`, then run `flutter build apk --release`. If `key.properties` is absent or incomplete, the release build fails fast; use `flutter build apk --debug` for local unsigned testing.

## Security-sensitive settings

- Training uploads require the private server key configured in **Training Settings > Advanced > Training API Key**.
- The training API key is stored with `flutter_secure_storage` when secure storage is available.
- The app does not ship a default training API key.
- The training server URL defaults to `https://discflightschool.onrender.com` and can be changed in Training Settings.
- Downloaded detector models are accepted only when the server-provided SHA-256 matches the downloaded bytes.

## Current limitations and next steps

- **TODO: verify the track-by-detection pipeline against a real throw video on a
  real device.** `flutter analyze`/`flutter test` cover the pure-function logic
  (candidate selection, coherence filtering, smoothing, and — as of the
  YOLO11n@640 swap — the NHWC/NCHW layout detection and both preprocessing
  write paths) but not the FFmpeg extraction command, the GPU delegate, or the
  discovery/tracking/occlusion state machine end to end. See `../docs/testing.md`.
- There is no repository/persistence abstraction layer; each service owns its
  own storage directly. Introducing one is not currently planned.
- Android APK generation is not yet represented as a committed CI artifact.
