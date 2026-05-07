# Phase 3 Architecture Decision Records — DiscFlightSchool Rebuild

This document starts Phase 3 by making the rebuild architecture decisions requested after the Phase 1 audit and Phase 2 synthesis. It does not implement the rebuild. Each major decision includes context, options considered, decision, rationale, and accepted trade-offs, followed by an integration coherence check.

## Target Architecture Summary

DiscFlightSchool should be rebuilt as a strongly typed, offline-first Flutter mobile application plus a Python ML/training backend. The client remains responsible for core user workflows that must work on-device: video selection/playback, TFLite disc detection, ML Kit pose analysis, baseline comparison, roulette, local history, and offline knowledge-base browsing. The backend becomes a production-grade training/model distribution service: authenticated upload-compatible REST endpoints, durable metadata in PostgreSQL, binary assets in object storage, and queued YOLO training workers.

The architecture intentionally preserves observable contracts from the current system while replacing ad hoc persistence and operational weak spots. The app keeps the existing user-visible workflows and server endpoint shapes, but moves local structured data to versioned SQLite tables, keeps secrets in secure storage, uses generated typed API clients/models, and treats model updates atomically. The server keeps FastAPI/Python because Python is the natural runtime for YOLO/Ultralytics, but formalizes validation with Pydantic, migrations with Alembic, background work with a durable queue, and observability with structured logs, metrics, and traces.

## ADR-001: Language and Runtime Selection

### Context

Phase 2 requires a cross-platform client with on-device video, TFLite inference, pose detection, secure storage, local persistence, and offline UX. It also requires a backend that can validate uploads, manage training datasets, run YOLOv8/Ultralytics training/export, and distribute TFLite models.

### Options Considered

1. **Keep Flutter/Dart client + Python backend**
   - Strong cross-platform UI/runtime support, mature Flutter plugins for current native needs, and Python-first ML training ecosystem.
2. **React Native/TypeScript client + Python backend**
   - Strong type ecosystem and web-team legibility, but weaker fit for existing TFLite/ML Kit/video plugin behavior and greater migration risk for native media workflows.
3. **Native Swift/Kotlin clients + Python backend**
   - Best native control/performance, but doubles client implementation and test burden.
4. **Single-language TypeScript full stack**
   - Good generated types and web ergonomics, but poor fit for YOLO training and native mobile ML/video requirements.
5. **Rust/Go backend + Python training sidecar**
   - Strong server performance and safety, but adds a second backend runtime while Python is still required for training.

### Decision

Use **Flutter/Dart** for the mobile/client application and **Python 3.12+ with FastAPI/Pydantic** for the backend API and training orchestration. Use Python worker containers for YOLO training/export jobs. Keep generated native shells only as build targets, not business-logic locations.

### Rationale

- Flutter/Dart provides a single typed client codebase for Android, iOS, and desktop/web-adjacent builds while supporting the current plugin needs: video playback, thumbnails, secure storage, ML Kit, and TFLite.
- Dart's null safety and sealed/typed model support are sufficient for client contracts when paired with generated serializers and repository boundaries.
- Python is the most operationally simple backend runtime for Ultralytics/YOLO training, image tooling, and ML model export.
- FastAPI/Pydantic gives typed request/response validation and OpenAPI generation without adding a separate schema server.
- This keeps the inter-process boundary explicit: Flutter talks to FastAPI over HTTPS REST using JSON, multipart form-data, and binary model downloads.

### Trade-offs Accepted

- The product remains multi-language, so CI must run Dart/Flutter and Python pipelines.
- Flutter web support remains secondary because several native ML/video plugins are mobile-first.
- Python is less type-safe than Rust/Go, so the backend must enforce strict type checking, Pydantic models, Ruff, mypy/pyright, and tests.

## ADR-002: Client Application Architecture and State Management

### Context

The current Flutter app uses large `ChangeNotifier` services and screens with mixed UI, persistence, analysis, and networking responsibilities. Phase 2 requires preserving workflows while improving testability, type safety, local persistence, and offline behavior.

### Options Considered

1. **Provider/ChangeNotifier retained with stricter service boundaries**
   - Minimal migration, but still weak for complex async state and testing.
2. **Riverpod + feature modules + repositories/use cases**
   - Strong typed dependency injection, testability, async state handling, and gradual migration from Provider.
3. **BLoC/Cubit**
   - Mature and testable, but more boilerplate for the app's mixed local/async workflows.
4. **Redux-style global store**
   - Predictable state, but excessive ceremony for media/ML workflows.

### Decision

Use **Riverpod** for dependency injection and feature state, with feature-oriented modules organized as `features/<domain>/{data,domain,presentation}`. Use repository interfaces for local persistence, model files, media files, server APIs, and AI APIs. Keep pure domain services for angle calculations, roulette generation/scoring, detector post-processing, and baseline comparison.

### Rationale

- Riverpod removes implicit `BuildContext` dependencies from business logic and enables direct provider overrides in tests.
- Feature modules keep Flight Tracker, Form Coach, Roulette, Knowledge Base, Settings, and Gallery independently testable.
- Repositories isolate persistence/networking from UI and make migration/compatibility tests straightforward.
- Pure domain services allow deterministic happy-path/error/edge-case coverage required by Phase 2.

### Trade-offs Accepted

- The team must learn Riverpod patterns if accustomed to Provider.
- Initial rebuild requires explicit model/repository scaffolding before UI velocity increases.
- Some existing `ChangeNotifier` logic will be rewritten rather than mechanically ported.

## ADR-003: Client Data Layer and Local Persistence

### Context

Current local persistence relies heavily on SharedPreferences, JSON files, and filesystem conventions. Phase 2 requires preserving local data contracts, legacy migrations, offline behavior, secure secrets, and atomic model updates.

### Options Considered

1. **Continue SharedPreferences/JSON**
   - Simple, but weak schema evolution, querying, and integrity.
2. **SQLite with Drift ORM + secure storage + filesystem blobs**
   - Strong local schema/migrations, typed queries, offline-first support, and clear blob boundaries.
3. **Isar/ObjectBox**
   - Fast object storage, but less transparent relational migration strategy for contracts like scored rounds and samples.
4. **Realm/Firebase local-first stack**
   - Powerful sync options, but introduces unnecessary cloud coupling.

### Decision

Use **SQLite via Drift** for structured local data, **Flutter Secure Storage** for secrets, and the app documents directory for large media/model/sample blobs. Keep a compatibility importer for existing SharedPreferences keys and JSON files.

### Rationale

- Drift provides typed Dart tables, migrations, and testable in-memory databases.
- SQLite is ideal for local form history, roulette history, training sample metadata, downloaded model metadata, knowledge-base indexes, and settings.
- Secure storage remains the correct location for Anthropic and training API keys.
- Large files should stay in the filesystem to avoid bloating SQLite; SQLite stores metadata and integrity hashes.

### Trade-offs Accepted

- Adds schema migration responsibility to the app.
- Requires a one-time legacy import layer from SharedPreferences/JSON.
- Database corruption/recovery paths must be tested.

## ADR-004: Backend API Paradigm and Contract Strategy

### Context

The current backend exposes a small REST API consumed by the app and operators. Phase 2 requires preserving observable endpoint behavior while improving validation, generated contracts, and test coverage.

### Options Considered

1. **REST with FastAPI OpenAPI generation**
   - Matches current endpoints and client expectations; supports multipart and file downloads naturally.
2. **GraphQL**
   - Flexible querying, but unnecessary for small command/file-oriented API and poor fit for binary model downloads.
3. **gRPC**
   - Strong contracts and streaming, but adds mobile integration and operational complexity; multipart/browser interactions are less natural.
4. **tRPC**
   - Strong TypeScript fit, but the client is Dart and backend is Python.

### Decision

Use **REST over HTTPS** with FastAPI, Pydantic v2 request/response models, OpenAPI as the source for generated clients/tests, and explicit compatibility endpoints for all existing routes.

### Rationale

- Existing app/server interactions are REST/multipart/file-download contracts; preserving them minimizes breaking changes.
- FastAPI OpenAPI supports generated Dart clients and contract tests.
- REST keeps operator workflows simple with `curl` and standard tooling.
- File uploads, ZIP export, and TFLite downloads map cleanly to HTTP semantics.

### Trade-offs Accepted

- REST does not provide end-to-end compile-time types by itself; generated clients and contract tests must close the gap.
- Versioning discipline is required to evolve endpoints without breaking existing app builds.

## ADR-005: Backend Data Layer, Blob Storage, and Job State

### Context

The current server stores dataset files, models, stats, export ZIPs, and training status on local disk/in memory. Phase 2 identifies durability, restart safety, and observability gaps.

### Options Considered

1. **Local filesystem only**
   - Simple and compatible with current code, but not durable or horizontally scalable.
2. **PostgreSQL + object storage + Redis-backed job queue**
   - Durable metadata, scalable blob handling, and reliable background jobs.
3. **SQLite + local object directory**
   - Good for single-node deployments, but insufficient for production training/distribution.
4. **Managed NoSQL document database + object storage**
   - Flexible, but relational constraints and migrations are clearer in PostgreSQL.

### Decision

Use **PostgreSQL** for server metadata, **S3-compatible object storage** for uploaded images/crops/exports/models, **Alembic** for migrations, and **Redis Queue/RQ or Celery** for durable training jobs. Keep local filesystem storage as the development adapter.

### Rationale

- PostgreSQL cleanly models samples, labels, uploads, model versions, training jobs, users/keys, and audit events.
- Object storage is the right abstraction for large images, ZIP exports, and TFLite artifacts.
- Durable queues make `/api/training/status` reliable across API restarts and allow worker isolation.
- A storage adapter preserves simple local development and enables test fixtures.

### Trade-offs Accepted

- Requires managed backing services in production instead of a single filesystem-only container.
- Requires migrations and backup/restore procedures.
- Training job consistency must handle object-store/database partial failure paths.

## ADR-006: ML/Vision Processing and Model Lifecycle

### Context

Core user value depends on on-device disc detection, pose analysis, pro baseline comparison, and periodic detector improvement. The rebuild must preserve offline analysis and verified model updates.

### Options Considered

1. **All analysis on-device, training server only for model lifecycle**
   - Preserves offline UX and privacy while supporting improved detectors.
2. **Cloud inference for flight/form analysis**
   - Centralized models and easier updates, but worse latency/privacy/offline behavior and higher cost.
3. **Hybrid cloud inference fallback**
   - Flexible but increases product complexity and creates inconsistent user results.

### Decision

Keep **inference on-device**: TFLite for disc detection and platform ML Kit pose detection for posture. Keep **training/export server-side** in Python workers. Treat pro baseline data and knowledge-base data as versioned bundled assets, with future optional OTA asset updates using the same signed/hash-verified model-update pattern.

### Rationale

- On-device processing meets offline, latency, and privacy expectations.
- TFLite is the right mobile model format for detector distribution.
- Python workers remain best suited for YOLO training/export.
- Hash-verified model lifecycle already exists as observable behavior and should be strengthened, not replaced.

### Trade-offs Accepted

- Mobile devices limit model size and inference throughput.
- Platform ML Kit behavior may vary by OS/device, requiring fixture tolerances.
- OTA baseline/content update support is deferred unless prioritized in Phase 4.

## ADR-007: Authentication, Secrets, and Authorization

### Context

The existing server protects mutating training endpoints with `X-App-Key`, while model/version/status endpoints are public. The app stores training and Anthropic API keys in secure storage with legacy migration.

### Options Considered

1. **Preserve single shared `X-App-Key` only**
   - Compatible and simple, but weak auditability and rotation.
2. **Per-device/operator API keys with hashed server storage, preserving `X-App-Key` header**
   - Compatible wire contract with better rotation and audit trails.
3. **OAuth/OIDC user accounts**
   - Strong identity model, but likely excessive for current app/operator scope.
4. **Signed upload URLs only**
   - Good for blobs but insufficient for training commands and compatibility.

### Decision

Preserve `X-App-Key` as the compatibility auth header, but implement **rotatable per-operator/per-environment API keys** stored hashed server-side. Keep client secrets in platform secure storage. Public model/version/status endpoints remain public unless Phase 4 discovers a product requirement for private models.

### Rationale

- Keeps existing app behavior and documented operator `curl` workflows intact.
- Enables key revocation, rotation, environment separation, and audit logging.
- Avoids full account/auth complexity until user identity is a product requirement.

### Trade-offs Accepted

- API-key auth is weaker than full user identity and does not distinguish end users unless keys are issued per user/device.
- Public model downloads can be scraped; acceptable only while models are not confidential.

## ADR-008: Deployment and Infrastructure Model

### Context

The current server can run as a Docker/Procfile app but stores critical state locally. Phase 2 requires production reliability, configurable secrets, background training, health/status endpoints, and minimal operational complexity.

### Options Considered

1. **Single VM/container with persistent disk**
   - Simple, but fragile and hard to scale/recover.
2. **Container-native API + worker + managed Postgres/object storage/Redis**
   - Strong reliability while keeping deployment understandable.
3. **Serverless functions only**
   - Good for simple endpoints, poor fit for large multipart uploads and long training jobs.
4. **Full Kubernetes from day one**
   - Flexible, but operationally heavy for the current product size.

### Decision

Use a **container-native deployment**: one API container, one or more worker containers, managed PostgreSQL, managed Redis/queue, S3-compatible object storage, and managed secret storage. For local development, provide Docker Compose with API, worker, Postgres, Redis, and MinIO.

### Rationale

- Separates latency-sensitive HTTP handling from long-running training work.
- Managed data services reduce undifferentiated operational burden.
- Docker Compose keeps local development reproducible.
- The same containers can run on a managed container platform now and Kubernetes later if needed.

### Trade-offs Accepted

- More moving parts than the current single FastAPI process.
- Requires infrastructure provisioning and environment-specific configuration.
- GPU training workers may require a specialized worker pool if CPU training becomes too slow.

## ADR-009: Observability and Operational Diagnostics

### Context

The current baseline has `/health`, in-memory training status, server logs, and local feedback JSON. Phase 2 requires better production diagnostics while preserving health/status behavior.

### Options Considered

1. **Keep framework logs only**
   - Minimal effort, insufficient for upload/training failure diagnosis.
2. **Structured logs + metrics + traces with OpenTelemetry**
   - Standard production visibility and vendor-neutral export.
3. **Vendor-specific APM SDK only**
   - Faster setup for one platform, but creates lock-in.

### Decision

Use **structured JSON logs**, **OpenTelemetry tracing**, and **RED metrics** (rate, errors, duration) for API endpoints, plus job metrics for queue depth, training duration, training failures, model export success, and upload validation failures. Propagate request IDs from API responses/logs into worker jobs.

### Rationale

- JSON logs and request IDs make support/debugging practical.
- OpenTelemetry allows later choice of backend without redesign.
- RED metrics match the small API surface and expose the critical reliability signals.
- Job metrics address the biggest current operational blind spot: background training.

### Trade-offs Accepted

- Adds instrumentation work and test assertions for logging/metrics boundaries.
- Trace cardinality must be managed to avoid excessive cost.

## ADR-010: Testing, CI/CD, and Release Strategy

### Context

Phase 2 identifies stale Flutter tests and sparse server validation checks. A rebuild requires tests-first behavior and integration-boundary verification.

### Options Considered

1. **Only unit tests per language**
   - Fast but misses API/client/storage integration failures.
2. **Layered test pyramid with contract tests and smoke E2E**
   - Better coverage of critical behavior with controlled cost.
3. **Heavy full-device E2E for every feature**
   - High confidence but too slow/flaky as the primary CI gate.

### Decision

Use a **layered CI pipeline**:

- Dart: format, analyze, unit tests, widget/golden smoke tests, generated-code freshness checks.
- Python: Ruff format/lint, mypy/pyright, unit tests, FastAPI HTTP contract tests, migration tests.
- Integration: Docker Compose API/worker/Postgres/Redis/object-storage boundary tests.
- Release: signed mobile builds and container image builds with SBOM and vulnerability scanning.

### Rationale

- Directly addresses the current lack of meaningful Flutter coverage.
- Contract tests protect existing endpoint shapes.
- Integration tests verify the Phase 3 coherence assumptions before production.
- Generated-client freshness prevents OpenAPI/client drift.

### Trade-offs Accepted

- CI will be slower than documentation-only or unit-only checks.
- Golden/device tests require careful fixture management and may need platform-specific runners.

## Integration Coherence Check

### Component Communication

- Flutter client ↔ FastAPI API: HTTPS REST using JSON for metadata/status, multipart form-data for training uploads, and binary HTTP responses for TFLite/ZIP downloads.
- FastAPI API ↔ PostgreSQL: SQLAlchemy/SQLModel repository layer with Alembic migrations.
- FastAPI API ↔ Object storage: S3-compatible SDK through a storage adapter for images, crops, exports, and models.
- FastAPI API ↔ Redis queue: enqueue training/export jobs with request id, key id/operator id, sample/model ids, and object storage keys.
- Worker ↔ PostgreSQL/Object storage/Redis: same typed adapters as API, isolated long-running YOLO subprocess execution.
- Flutter client ↔ platform services: Flutter plugins for media, secure storage, ML Kit, TFLite, filesystem, and preferences migration.
- Flutter client ↔ Anthropic API: HTTPS JSON through an AI repository that is optional and unavailable offline.

### Data Type Round-Trip

- Training labels remain YOLO class-0 normalized decimal strings at the HTTP and dataset-file boundary; client database stores them as doubles and formats them to six decimals for upload compatibility.
- Sample ids remain ASCII-safe strings constrained by the existing regex before they become database ids, object keys, or filenames.
- Dates/times use ISO-8601 strings at JSON boundaries and timezone-aware database timestamps server-side.
- Model hashes remain lowercase SHA-256 hex strings across server metadata, JSON responses, client database rows, and verification code.
- Roulette enum values retain existing serialized names to preserve saved history compatibility.
- Knowledge-base and pro-baseline JSON assets retain current field names; importers tolerate nullable/missing measurement values.
- Binary image/model/ZIP payloads are never JSON-encoded; they move through multipart/object storage/file download boundaries as bytes.

### Auth and Credential Flow

- Training API keys are entered by users/operators, stored in platform secure storage, and sent only as `X-App-Key` to compatibility endpoints.
- Server stores only hashed API keys and records key id/operator/environment in audit logs after validation.
- Anthropic keys are stored separately in platform secure storage and sent only to Anthropic HTTPS endpoints.
- Backend service credentials for PostgreSQL, Redis, object storage, and telemetry are injected via environment variables/secrets manager into containers.
- Request ids are not secrets and may flow through logs, response headers, and queued job metadata.

### Hosting and Runtime Compatibility

- Flutter/Dart client builds are handled by Flutter SDK CI runners and distributed through app stores or platform artifacts.
- FastAPI API and Python workers share one Python base image family but run separate container commands.
- PostgreSQL, Redis, and object storage are available locally through Docker Compose and in production through managed services.
- YOLO training runs inside worker containers; if GPU acceleration is needed, only the worker pool requires GPU-capable nodes/runners.
- No selected component requires a runtime unavailable to the proposed container-native infrastructure.

### CI/CD Compatibility

- The pipeline supports Dart/Flutter and Python jobs independently, then runs Docker Compose integration tests.
- OpenAPI generation connects backend schema changes to Dart client regeneration.
- Alembic migration checks ensure database schemas match code.
- Container image builds cover API and worker runtimes.
- Mobile signing/release remains separate from backend deployment but can share commit/version metadata.

## Phase Boundary

Phase 3 is complete as an architecture decision baseline. The next step is Phase 4 Rebuild, where these ADRs should be implemented with tests-first development and a migration plan for existing local/server state.
