# Flutter Data-Layer Migration Plan

This is the Step 5 remote/virtual foundation for rebuilding the Flutter client data layer. It introduces typed repository boundaries without replacing UI flows yet, so existing screens and services can be migrated incrementally.

## Implemented Foundation

- Added repository interfaces for training samples, detector model metadata/downloads, roulette history, form history, and knowledge-base content.
- Extracted `FormSessionRecord` into `lib/models/form_session_record.dart` so form-history contracts can be shared without importing a `ChangeNotifier` service.
- Added detector model metadata/version models for local model records and `/api/model/version` responses.
- Added data-contract tests for training sample YOLO formatting, legacy roulette score parsing, form history legacy defaults, and no-model version responses.

## Migration Sequence

1. Add Drift/SQLite tables matching the repository interfaces.
2. Build SharedPreferences/JSON importers for legacy keys and files.
3. Run importers once during app startup before UI reads repository data.
4. Keep existing services as adapters over the repositories during transition.
5. Remove direct SharedPreferences persistence from services only after repository-backed tests cover the same behavior.

## Legacy Contracts To Preserve

- `TrainingSample.uploaded` defaults to `false` when absent.
- `TrainingSample.toYoloLabel()` emits class `0` and six fixed decimal places.
- `HoleScore.fromJson()` accepts legacy single-`challenge` records.
- `FormSessionRecord.throwType` defaults to `BH` when absent.
- `/api/model/version` no-model sentinel remains `version: none`, empty `sha256`, and empty `url`.
