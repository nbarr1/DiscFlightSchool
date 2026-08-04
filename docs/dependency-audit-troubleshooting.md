# Dependency audit troubleshooting

`.github/workflows/dependency-audit.yml` runs two independent checks.

| Check | Tool | Covers |
|---|---|---|
| **Python dependency audit** | `pip-audit` | `server/requirements.txt`, `server/requirements-test.txt` |
| **OSV lockfile audit** | OSV-Scanner | `disc_golf_app/pubspec.lock` |

## Why Python is audited by pip-audit and not by OSV

The Python files are **manifests with version ranges**, not lockfiles. OSV
resolves each range to its *lowest* satisfying version before matching
advisories, so it reports vulnerabilities against versions `pip` would never
install — and those findings are mostly unfixable from this repository, because
they come from transitive dependencies whose parents floor them low (`h11` via
`uvicorn`, `torch` via `ultralytics`). Even the newest `uvicorn` still declares
`h11>=0.8`, so no pin here can move OSV's resolution off the vulnerable version.

`pip-audit` resolves the same files the way `pip` actually does, so it is the
correct tool for them. Adding them back to the OSV scan produces failures that
contradict the pip-audit result on the same commit.

If you later add a real Python lockfile (`pip-compile` output, for example),
scan *that* with OSV — a lockfile pins exact versions and the resolution
mismatch disappears.

## How to read a failing Python dependency audit

`pip-audit` exits non-zero when it finds a known vulnerability or cannot resolve
the requirements. The job writes a JSON report per file before failing:

1. Open the failed GitHub Actions run.
2. Download the `pip-audit-reports` artifact.
3. Inspect `server-pip-audit.json` and `server-test-pip-audit.json`.
4. For each vulnerability, raise the package to one of the listed
   `fix_versions`.

Remediation notes:

- Prefer raising the **floor of the direct dependency**. A range like
  `python-multipart>=0.0.6` is a finding in its own right if the range still
  admits a vulnerable release, even when `pip` currently installs a safe one.
- If the vulnerable package is transitive, raise the lower bound of whichever
  direct dependency brings it in. Pin the transitive package directly only as a
  last resort — it makes this repo responsible for a version it does not own.
- Reproduce locally on Python 3.11 to match the workflow; compiled packages
  publish wheels for a limited set of versions.

```bash
python -m pip install --upgrade pip pip-audit
python -m pip_audit --progress-spinner off --format=json \
  --output=/tmp/server-pip-audit.json -r server/requirements.txt
python -m pip_audit --progress-spinner off --format=json \
  --output=/tmp/server-test-pip-audit.json -r server/requirements-test.txt
```

### The two requirements files must agree

`server/requirements-test.txt` exists so CI can install the server's
dependencies without `ultralytics` (which pulls ~2GB of torch and is only
needed to run an actual training job). Every package the two files share must
carry an **identical** specifier; `server/test_requirements.py` fails the build
otherwise.

This is not hypothetical: CI once installed `Pillow>=10.0.0,<12.0.0` while
production required `Pillow>=12.3.0` — two ranges with no overlap, so the
image-validation tests were exercising a major version the app would never run.
Bump both files together.

## How to read a failing OSV lockfile audit

OSV-Scanner exits non-zero when it finds known vulnerabilities in a scanned
lockfile. Current input: `disc_golf_app/pubspec.lock`.

For Dart findings, update `disc_golf_app/pubspec.yaml` and regenerate the
lockfile with `flutter pub get`. Do not resolve a finding by widening a version
range without regenerating the lockfile — the scanner must be able to see the
safe resolved version.

```bash
osv-scanner scan source --lockfile=disc_golf_app/pubspec.lock
```

## Workflow hardening

- Third-party actions are pinned to stable major versions rather than `@main`,
  so an unreleased upstream change cannot break pushes.
- The OSV action is referenced as
  `google/osv-scanner-action/osv-scanner-action@v2.3.8`. The **repository root
  has no `action.yml`** — referencing `google/osv-scanner-action@v2.3.8`
  fails with `Top level 'runs:' section is required` before the scan starts.
  If this check ever fails with that message, the path lost its subdirectory.
- The scan lists explicit lockfiles rather than scanning recursively, so
  generated build directories are never picked up.
