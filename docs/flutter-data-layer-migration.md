# Flutter Data-Layer Migration Status

Audited on 2026-05-10.

## Current state

Repository interfaces exist under `disc_golf_app/lib/data/repositories/` for:

- Detector model metadata/download boundaries.
- Form history sessions.
- Knowledge-base content.
- Roulette spin history and scored rounds.
- Training samples.

Shared models currently extracted for migration support include:

- `FormSessionRecord`.
- `DetectorModelMetadata`.
- `DetectorModelVersion`.

Data-contract tests currently cover:

- `TrainingSample.uploaded` defaulting to `false` for legacy JSON.
- `TrainingSample.toYoloLabel()` formatting class `0` with six decimal places.
- Legacy single-challenge `HoleScore` parsing.
- `FormSessionRecord.throwType` defaulting to `BH` for legacy JSON.
- The no-model `DetectorModelVersion` sentinel.

## Important limitation

The repository interfaces are not yet wired as concrete persistence adapters for the existing UI flows. Current services still use direct local persistence mechanisms such as SharedPreferences, files, and secure storage.

## Safe migration sequence

1. Add concrete local adapters behind the existing repository interfaces.
2. Add tests for each adapter using realistic legacy data.
3. Add one-time import/migration code for existing SharedPreferences/file-backed data.
4. Update services to depend on repositories while preserving public service behavior.
5. Update screens only after service-level behavior is covered by tests.
6. Remove legacy direct persistence paths after migration tests prove compatibility.
