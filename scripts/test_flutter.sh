#!/usr/bin/env bash
set -euo pipefail

if ! command -v flutter >/dev/null 2>&1; then
  echo "ERROR: flutter is not installed or not on PATH" >&2
  exit 127
fi

pushd disc_golf_app >/dev/null
flutter pub get
flutter analyze
flutter test
popd >/dev/null
