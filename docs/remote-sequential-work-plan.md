# Remote Sequential Work Plan

Audited on 2026-05-10.

## Step 1: Verify local/CI toolchains

- Confirm Python dependencies install and `./scripts/test_server.sh` passes.
- Confirm Flutter is installed and `./scripts/test_flutter.sh` passes.
- Confirm Android SDK compile SDK 36, NDK `27.0.12077973`, and Java 17 are available.

## Step 2: Produce a testable APK

```bash
cd disc_golf_app
flutter doctor -v
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Expected artifact:

```text
disc_golf_app/build/app/outputs/flutter-apk/app-debug.apk
```

Install/smoke-test on an Android device or emulator:

```bash
adb install -r disc_golf_app/build/app/outputs/flutter-apk/app-debug.apk
```

Smoke-test checklist:

- App launches.
- Onboarding/home routing works.
- Home buttons navigate.
- Training Settings opens without requiring a bundled API key.
- Bundled model asset can initialize Flight Tracker paths that rely on it.
- Knowledge Base loads bundled JSON.

## Step 3: Harden client persistence migration

- Implement one repository adapter at a time.
- Add tests for legacy import/default behavior.
- Switch services to adapters only after tests pass.

## Step 4: Harden server durability

- Add database schema and migrations.
- Add object-storage adapter.
- Add Redis queue adapter.
- Move training execution to the worker.
- Add compose-backed integration tests.

## Step 5: Release readiness

- Decide debug/internal testing vs release signing.
- For release distribution, create a real Android keystore and `android/key.properties` outside source control.
- Add CI artifact upload if every merge should produce a test APK.
