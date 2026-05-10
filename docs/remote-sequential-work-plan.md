# Remote Sequential Work Plan

This plan breaks the remaining rebuild work into reviewable remote/virtual slices. Each step should land in its own PR unless the change is purely mechanical and tightly coupled to the prior step.

## Step 1 — Server CI Gate

**Status:** Implemented in this update.

**Goal:** Make the Phase 4 server foundation remotely verifiable on every PR without requiring local developer machines.

**Deliverables:**

- GitHub Actions workflow for server unit/contract tests on Python 3.11 and 3.12.
- A single local/remote shell entrypoint for the same checks.
- No dependency on YOLO training binaries for contract tests.

**Validation:**

- Python compile checks for `server/main.py`, server tests, and `server/training_server/*.py`.
- `pytest` execution of `server/test_validation.py` and `server/test_http_contracts.py`.

## Step 2 — Server Observability Foundation

**Status:** Implemented in this update.

**Goal:** Add structured JSON logs, request IDs, and endpoint duration/error logging while preserving response bodies and status codes.

**Deliverables:**

- Request ID middleware accepting `X-Request-ID` or generating one.
- Response `X-Request-ID` header.
- Structured logs for request start/finish, including status codes for validation failures.
- Contract tests proving request IDs are returned and existing responses are unchanged.

## Step 3 — Server Configuration Hardening

**Status:** Implemented in this update.

**Goal:** Fail fast on invalid configuration and document remote deployment settings.

**Deliverables:**

- Validation for positive `MAX_UPLOAD_BYTES`.
- Optional environment variable for training command timeout/epochs/batch/image size.
- Tests for invalid environment values.
- README updates for all configuration values.

## Step 4 — Server Storage Adapter Boundary

**Status:** Implemented in this update.

**Goal:** Prepare for PostgreSQL/object-storage migration without changing the current filesystem behavior.

**Deliverables:**

- Protocol/interface types for sample metadata storage, blob storage, model metadata, and export generation.
- Filesystem adapter remains the default.
- Tests run against the adapter interface.
- Keep export generation thread-safe with unique ZIP paths and cleanup after responses.
- App factory accepts an injected storage backend so future durable adapters can be tested without changing endpoint code.

## Step 5 — Flutter Data-Layer Foundation

**Status:** In progress; repository contracts and migration plan are implemented, Flutter SDK validation remains pending.

**Goal:** Start the client rebuild without replacing UI flows first.

**Deliverables:**

- Typed repository interfaces for training samples, model metadata, roulette history, form history, and knowledge-base loading.
- Serialization tests for legacy JSON contracts.
- A migration plan from SharedPreferences/JSON to SQLite/Drift.
- Next: add Drift tables and repository implementations once Flutter tooling is available in CI.

## Step 6 — Flutter CI/Test Repair

**Status:** Implemented in this update.

**Goal:** Replace the stale starter widget test with meaningful smoke/model tests that can run remotely.

**Deliverables:**

- Confirm the stale counter-style widget test has been replaced by app startup routing tests.
- Add tests for app startup routing and pure model serialization.
- Update GitHub Actions to run `flutter analyze` and `flutter test` before APK build.
- Add a reusable remote/local Flutter test script mirroring the CI test workflow.

## Step 7 — Durable Server Runtime

**Status:** In progress; compose stack, environment schema, and worker scaffold are implemented.

**Goal:** Add production adapters for durable metadata, blob storage, and queued training jobs.

**Deliverables:**

- PostgreSQL metadata schema and migrations.
- S3-compatible blob adapter.
- Redis/Celery or RQ training job adapter.
- Docker Compose for API, worker, database, queue, and object storage.
- Next: replace the worker scaffold with a real Redis-backed training job adapter.

## Remote Execution Rules

- Prefer tests that do not require cameras, GPUs, app stores, or physical devices.
- Keep every step compatible with CI runners and containerized services.
- Preserve the observable contracts documented in Phase 2 unless a delta is explicitly approved.
- Do not start a later step until the prior step has a passing remote validation path.
