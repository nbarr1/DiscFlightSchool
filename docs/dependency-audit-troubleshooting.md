# Dependency audit troubleshooting

This repository has two GitHub checks in `.github/workflows/dependency-audit.yml`:

- **Dependency Audit / Python dependency audit (push)** runs `pip-audit` against the two Python requirement manifests:
  - `server/requirements.txt`
  - `disc_golf_app/python/requirements.txt`
- **Dependency Audit / OSV lockfile audit (push)** runs OSV-Scanner against the repository dependency lockfiles/manifests.

## How to read a failing Python dependency audit

`pip-audit` exits non-zero when it finds a known vulnerability or when it cannot resolve the requirements. The job now writes a JSON report for each requirements file before failing, so the fastest way to troubleshoot is:

1. Open the failed GitHub Actions run.
2. Download the `pip-audit-reports` artifact.
3. Inspect `server-pip-audit.json` and `prototype-pip-audit.json`.
4. For each vulnerability, upgrade the package to one of the listed `fix_versions` when available.

Common remediation patterns:

- Prefer upgrading direct dependencies in the relevant `requirements.txt` file.
- If the vulnerable package is transitive, raise the lower bound of the direct dependency that brings it in, or pin/constraint the transitive package only when the upstream direct dependency has not released a safe resolver range yet.
- Keep the Python version aligned with the workflow (`3.11`) when reproducing locally because compiled packages such as computer-vision dependencies publish wheels for a limited set of Python versions.

Local reproduction command:

```bash
python -m pip install --upgrade pip pip-audit
python -m pip_audit --progress-spinner off --format=json --output=/tmp/server-pip-audit.json -r server/requirements.txt
python -m pip_audit --progress-spinner off --format=json --output=/tmp/prototype-pip-audit.json -r disc_golf_app/python/requirements.txt
```

## How to read a failing OSV lockfile audit

OSV-Scanner exits non-zero when it finds known vulnerabilities in supported dependency files. The workflow now scans only the dependency files this repository intentionally maintains instead of recursively scanning generated application/build directories.

Current OSV inputs:

- `pnpm-lock.yaml`
- `disc_golf_app/pubspec.lock`
- `server/requirements.txt`
- `disc_golf_app/python/requirements.txt`

Recommended fixes:

- For JavaScript findings, update `pnpm-lock.yaml` from the root package manager workflow.
- For Flutter/Dart findings, update `disc_golf_app/pubspec.yaml` and regenerate `disc_golf_app/pubspec.lock` with `flutter pub get`.
- For Python findings, apply the same package upgrades recommended by the `pip-audit` report.
- Do not resolve an OSV finding by widening a version range without regenerating the corresponding lockfile/report; the check must be able to see the safe resolved version.

Local reproduction command:

```bash
osv-scanner scan source \
  --lockfile=pnpm-lock.yaml \
  --lockfile=disc_golf_app/pubspec.lock \
  --lockfile=requirements.txt:server/requirements.txt \
  --lockfile=requirements.txt:disc_golf_app/python/requirements.txt
```

## Workflow hardening applied

The workflow is intentionally pinned to stable major versions for third-party actions. It also avoids `@main` for OSV-Scanner so pushes are not broken by an unreleased upstream action change.
