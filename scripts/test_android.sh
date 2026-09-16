#!/usr/bin/env bash
set -euo pipefail

# The Gradle wrapper downloads its own distribution, so the only host
# requirement is a JDK 17 and the Android SDK for the :app module.
pushd disc_golf_android >/dev/null
./gradlew :core:test :app:testDebugUnitTest
popd >/dev/null
