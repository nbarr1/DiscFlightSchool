# Disc Flight School Flutter App

This directory contains the Flutter client for DiscFlightSchool. This README reflects the current source tree as audited on 2026-05-10.

## What is currently implemented

- App bootstrap in `lib/main.dart` with Provider-registered services and onboarding/home startup routing.
- Home navigation to Flight Tracker, Form Coach, Disc Roulette, Knowledge Base, Training Settings, and Flight Path Gallery.
- Flight Tracker screens and services for bundled/downloaded TFLite detection, manual keyframe-assisted tracking, overlays, video playback, and saved flight data.
- Form Coach screens and services for video selection/trimming, ML Kit pose analysis, phase comparison, pose correction, feedback, and local form-history persistence.
- Disc Roulette models, random challenge generation, scored rounds, scorecards, and local history persistence.
- Knowledge Base models/screens/services using bundled JSON assets, with optional API-key-backed AI search behavior in the UI.
- Training-data collection and upload support through `TrainingDataService`, with opt-in local sample collection and secure storage for the private training API key.
- Detector model update checks/downloads from the configured server, including SHA-256 verification before replacing the local model file.
- Repository interface definitions under `lib/data/repositories/`; these are migration boundaries and not complete concrete adapters.

## Key project facts

- Package: `disc_golf_app`.
- Version: `1.0.0+1`.
- Dart SDK: `>=3.8.0 <4.0.0`.
- Android application ID: `com.discflightschool.app`.
- Android compile SDK: `36`.
- Android NDK: `27.0.12077973`.
- Bundled model asset: `assets/models/disc_detector.tflite`.
- Bundled data assets: `assets/data/output_coordinates.json`, `assets/data/analysis_results.json`, `assets/data/pro_baseline_db.json`, and `assets/data/knowledge_base.json`.

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

For a release APK, create `android/key.properties` with `keyAlias`, `keyPassword`, `storeFile`, and `storePassword`, then run `flutter build apk --release`. If `key.properties` is absent, the current Android Gradle file uses debug signing for the release build type.

## Security-sensitive settings

- Training uploads require the private server key configured in **Training Settings > Advanced > Training API Key**.
- The training API key is stored with `flutter_secure_storage` when secure storage is available.
- The app does not ship a default training API key.
- The training server URL defaults to `https://discflightschool.onrender.com` and can be changed in Training Settings.
- Downloaded detector models are accepted only when the server-provided SHA-256 matches the downloaded bytes.

## Current limitations and next steps

- Repository interfaces are present, but existing services still own most persistence logic directly.
- Python files under `python/` are prototype helper/server code; the Flutter app does not embed Python directly.
- Android APK generation is not yet represented as a committed CI artifact.
- Add concrete repository adapters and migration tests before removing legacy SharedPreferences/JSON persistence paths.
