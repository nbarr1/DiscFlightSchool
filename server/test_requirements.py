"""Guards against CI testing a dependency version production forbids.

`requirements-test.txt` intentionally omits `ultralytics`, but every package it
*does* share with `requirements.txt` has to carry an identical specifier. This
previously drifted: CI installed `Pillow>=10.0.0,<12.0.0` while production
required `Pillow>=12.3.0` — two ranges with no overlap, so the image-validation
tests were exercising a major version the app would never run.
"""

from __future__ import annotations

import unittest
from pathlib import Path

SERVER_DIR = Path(__file__).resolve().parent
RUNTIME_REQUIREMENTS = SERVER_DIR / "requirements.txt"
TEST_REQUIREMENTS = SERVER_DIR / "requirements-test.txt"

# Packages allowed to appear in only one of the two files.
TEST_ONLY_PACKAGES = {"pytest"}
RUNTIME_ONLY_PACKAGES = {"ultralytics", "uvicorn", "gunicorn"}

_SPECIFIER_CHARS = "<>=!~ "


def parse_requirements(path: Path) -> dict[str, str]:
    """Map normalized package name -> full requirement line."""
    parsed: dict[str, str] = {}
    for raw_line in path.read_text().splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("-"):
            raise AssertionError(
                f"{path.name}: flags and nested includes are not supported here "
                f"(found {line!r}); keep these files flat so pip-audit and "
                f"osv-scanner can parse them."
            )
        name = line
        for index, char in enumerate(line):
            if char in _SPECIFIER_CHARS:
                name = line[:index]
                break
        parsed[name.strip().lower().replace("_", "-")] = line
    return parsed


class RequirementsConsistencyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.runtime = parse_requirements(RUNTIME_REQUIREMENTS)
        self.test = parse_requirements(TEST_REQUIREMENTS)

    def test_shared_packages_pin_identical_versions(self):
        shared = set(self.runtime) & set(self.test)
        self.assertTrue(shared, "expected the two files to share packages")
        for package in sorted(shared):
            self.assertEqual(
                self.runtime[package],
                self.test[package],
                f"{package} is pinned differently in requirements.txt and "
                f"requirements-test.txt; CI would test a version production "
                f"does not allow",
            )

    def test_no_unexpected_test_only_packages(self):
        test_only = set(self.test) - set(self.runtime)
        unexpected = test_only - TEST_ONLY_PACKAGES
        self.assertEqual(
            set(),
            unexpected,
            f"requirements-test.txt has packages absent from requirements.txt: "
            f"{sorted(unexpected)}. Add them to requirements.txt or to "
            f"TEST_ONLY_PACKAGES if they are genuinely test-only.",
        )

    def test_runtime_only_packages_are_declared(self):
        runtime_only = set(self.runtime) - set(self.test)
        unexpected = runtime_only - RUNTIME_ONLY_PACKAGES
        self.assertEqual(
            set(),
            unexpected,
            f"requirements.txt has packages the test environment never "
            f"installs: {sorted(unexpected)}. Either add them to "
            f"requirements-test.txt or to RUNTIME_ONLY_PACKAGES.",
        )

    def test_pillow_major_version_floor_is_current(self):
        # Pillow <12 was pulled from this project by a dependency audit
        # (CVE remediation). Catch any accidental downgrade.
        self.assertIn("pillow", self.runtime)
        self.assertIn(
            ">=12",
            self.runtime["pillow"],
            "Pillow must stay on 12.x or newer; earlier majors were removed "
            "by the dependency audit",
        )

    def test_no_flask_dependencies_in_fastapi_server(self):
        # The server is FastAPI-only; a Flask package here is always a
        # mistaken addition (flask-cors was previously pulled in by accident).
        for package in self.runtime:
            self.assertNotIn(
                "flask",
                package,
                f"{package} is a Flask dependency, but server/ is a FastAPI "
                f"app with no Flask imports",
            )


if __name__ == "__main__":
    unittest.main()
