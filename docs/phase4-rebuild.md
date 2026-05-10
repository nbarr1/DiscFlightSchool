# Phase 4 Rebuild Status

Audited on 2026-05-10.

## Completed in current source

- Server modules split into `training_server.app`, `config`, `storage`, `training`, `validation`, `protocols`, and `worker`.
- `server/main.py` delegates to the package while preserving compatibility helpers/constants.
- Server tests cover validation, HTTP contracts, config loading, and filesystem storage behavior.
- Docker Compose scaffold and env example were added for API/worker/Postgres/Redis/MinIO validation.
- Flutter repository interfaces and data-contract tests were added as data-layer migration foundations.
- Flutter build workflow now runs analyzer/tests before APK build in the existing build workflow.

## Not completed yet

- Durable storage/queue adapters.
- Real worker job consumption.
- Flutter concrete repository adapters.
- End-to-end server/client integration tests.
- Confirmed APK artifact from this execution environment.

## Immediate rebuild priorities

1. Restore/verify Flutter toolchain availability in CI and local build environments.
2. Run `./scripts/test_flutter.sh` and fix any analyzer/test failures.
3. Build `flutter build apk --debug` and smoke-test the resulting APK.
4. Add concrete repository adapters one feature at a time.
5. Add durable server adapters only with tests proving behavior parity against `FileStorage`.
