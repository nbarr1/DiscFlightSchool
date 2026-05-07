# Disc Flight School Flutter App

Flutter client for Disc Flight School. The app provides:

- Disc flight tracking with bundled or downloaded TFLite models.
- Manual tracking data collection with explicit opt-in.
- Form Coach pose analysis using Google ML Kit.
- Disc Roulette, including optional scored rounds.
- Offline knowledge-base search and optional Anthropic-powered Q&A.

## Setup

```bash
flutter pub get
flutter run
```

## Security-sensitive settings

Training uploads require a private server key. Configure it in **Training Settings > Advanced > Training API Key**; the key is stored with platform secure storage. The app no longer ships a default training key.

Anthropic API keys for AI knowledge-base search are also stored with platform secure storage.

## Model updates

Model downloads are checked from **Training Settings**. The app validates the server-provided SHA-256 before saving the downloaded `.tflite` file and reloads the detector after a successful update.
