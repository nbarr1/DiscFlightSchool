# Phase 3 Architecture Decisions Update

Audited on 2026-05-10.

## Current decisions reflected in source

### Keep FastAPI entrypoint compatibility

`server/main.py` remains the import target for Uvicorn/Gunicorn and exposes backwards-compatible constants/helpers while delegating route implementation to `training_server` modules.

### Keep filesystem storage as the implemented backend for now

`FileStorage` is the active storage implementation. It creates dataset/model/export directories, writes uploads to disk, tracks JSON stats, generates `dataset.yaml`, finds the latest model by modification time, and builds export ZIP files.

### Treat Docker Compose durability as a scaffold

PostgreSQL, Redis, and MinIO are defined in compose and parsed by settings, but they are not used by request handlers yet. Documentation should continue calling this a scaffold until adapters exist.

### Keep Flutter repository interfaces as migration boundaries

The client now has repository interfaces and shared data models, but existing services are still the production behavior path. Concrete adapters should be added behind the interfaces before changing UI flows.

### Build Android APKs from Flutter tooling

The Android project is Flutter-managed with Gradle Kotlin DSL. The reliable testable artifact path is a debug APK from `flutter build apk --debug` after analyzer and tests pass.

## Decisions still required

1. Choose the durable server metadata schema.
2. Choose queue/job semantics for training requests.
3. Choose local persistence technology for concrete Flutter repositories.
4. Decide whether CI should upload debug APK artifacts for every branch/PR.
5. Decide release signing and distribution process for Android builds.
