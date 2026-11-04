# DiscFlightSchool

DiscFlightSchool is a native Android app for disc golf form coaching, scored practice rounds, and a research-backed knowledge base.

The client was a Flutter app until the Kotlin rewrite; `disc_golf_app/` is gone and its history is in git. This README describes only files and behavior that exist in this repository.

Flight tracking, and the training server that collected data for its disc detector, were removed so flight tracking can be rebuilt from scratch. [Flight tracking rebuild reference](docs/flight-tracking-rebuild-reference.md) records the Roboflow Workflow the removed code mirrored, and the commit that last held it.

## Current repository status

### Android client (`disc_golf_android/`)

The Android app is the end-user application, written in Kotlin with Jetpack
Compose. `MainActivity` provides the process-wide `AppContainer` through a
composition local and hands off to `AppNavHost`, which routes first-time users
through onboarding before showing the home screen.

The Gradle project has two modules:

- **`:core`** — a plain Kotlin/JVM module with no Android dependencies. It holds
  the posture calculations, frame sampling, scoring, roulette, the
  knowledge-base search, and every persisted model. Because it is
  Android-free, all of it runs under a normal JVM test task.
- **`:app`** — the Android module: Compose UI, ML Kit integration, Media3
  playback, frame extraction, and storage.

Implemented client areas currently present in source:

- Form Coach screens for video trimming, posture analysis, phase selection/comparison, pose correction, and session history.
- Disc Roulette screens, scoring models, scoring repository, and roulette history.
- Knowledge Base screens and local JSON-backed content models/repositories.
- A privacy policy screen, reached from the home screen's app bar.

Screen-to-screen state that is too large to encode in a navigation route, such
as a pose analysis, lives in `WorkbenchState`; the routes
themselves carry only identifiers. Persistence is `SharedPreferences`,
`EncryptedSharedPreferences` for secrets, and files under the app's own storage.

Important client facts:

- Gradle project: `disc_golf_android/`, modules `:app` and `:core`, built with the committed Gradle wrapper (9.3.1).
- Android Gradle Plugin `9.1.0`, Kotlin `2.4.21`, Compose BOM `2026.09.00`, all pinned in `disc_golf_android/gradle/libs.versions.toml`. AGP 9 compiles Kotlin itself, so the Kotlin Android plugin isn't applied.
- Android application ID: `com.discflightschool.app`.
- `versionCode = 1`, `versionName = "1.0.0"`, declared in `disc_golf_android/app/build.gradle.kts`.
- `compileSdk = 37`, `targetSdk = 37`, `minSdk = 24`.
- Java/Kotlin target 17, with core library desugaring so `java.time` works at API 24.
- Release builds require a complete `disc_golf_android/key.properties` signing config; unsigned local testing should use debug builds.
- Bundled runtime assets live in `disc_golf_android/app/src/main/assets/`: `data/pro_baseline_db.json` and `data/knowledge_base.json`.
- `models/rfdetr/` under the assets folder stays git-ignored. If an earlier checkout downloaded the disc model there, delete the folder: Gradle still packages a file that git ignores.

#### Library choices carried over from the Flutter client

| Flutter package | Android replacement |
|---|---|
| `provider` | `AppContainer` + Compose state / `StateFlow` |
| `video_player` | Media3 ExoPlayer (`SeekParameters.EXACT` for frame-accurate scrubbing) |
| `ffmpeg_kit_flutter_new` | `MediaMetadataRetriever` for frame extraction |
| `google_mlkit_pose_detection` | `com.google.mlkit:pose-detection-accurate` |
| `image_picker` / `file_picker` | `ActivityResultContracts.PickVisualMedia` / `CaptureVideo` |
| `flutter_secure_storage` | `EncryptedSharedPreferences` |
| `shared_preferences` | `SharedPreferences` |

Frame extraction is the one substitution with a behavioural note worth knowing:
`MediaMetadataRetriever` is asked for `OPTION_CLOSEST` rather than the cheaper
`OPTION_CLOSEST_SYNC`, because snapping to the nearest keyframe would silently
misalign an overlay from the position it was measured at.

The on-disk formats — landmark key strings, ISO-8601 timestamps, the legacy
`challenge` field on a saved hole — are unchanged from the Flutter client, so an existing install keeps its
history. `DataContractsTest` covers those round trips.

## Project layout

```text
DiscFlightSchool/
├── .github/workflows/          # GitHub Actions for the Android build, tests, and lint
├── disc_golf_android/          # Android application (Gradle)
│   ├── app/                    # Android module: Compose UI, ML Kit, Media3
│   │   └── src/main/assets/    # JSON data
│   ├── core/                   # Pure Kotlin/JVM module: posture, frame sampling,
│   │                           #   scoring, and the persisted models, with its tests
│   └── art/                    # Source artwork for the launcher icon and basket drawable
├── docs/                       # testing.md, the flight tracking rebuild reference,
│   │                           #   the privacy policy, and the Google Play readiness report/plan
│   └── studies/                # The research papers the knowledge base cites
└── scripts/                    # Local test scripts
```

The Flutter client that preceded this one accumulated several layers of dead
code, all removed before the rewrite: a never-called prototype Flask service
and its bridge, a never-routed Flight Analysis screen with the services,
assets, models, and helpers behind it, and two other unrouted screens. One
more — `comparison_screen.dart`, which nothing navigated to — was found during
the port and deliberately not carried over. Recover any of it from git history
if you want to revive that path.

## Local development

### Android checks

```bash
./scripts/test_android.sh
```

The script runs `:core:test` and `:app:testDebugUnitTest` through the committed
Gradle wrapper, so the only host requirement is a JDK 17 plus the Android SDK
for the `:app` module. `:core` alone needs nothing but the JDK:

```bash
cd disc_golf_android
./gradlew :core:test
```

## Building a testable Android APK

Prerequisites:

1. Java 17.
2. Android SDK with compile SDK 37 and build tools installed (`ANDROID_HOME`, or a `local.properties` naming `sdk.dir`).
3. Network access for first-time dependency resolution unless dependencies are already cached.

Recommended validation/build sequence:

```bash
cd disc_golf_android
./gradlew :core:test :app:testDebugUnitTest
./gradlew :app:lintDebug
./gradlew :app:assembleDebug
```

Expected debug APK output:

```text
disc_golf_android/app/build/outputs/apk/debug/app-debug.apk
```

For a signed release build, add `disc_golf_android/key.properties` with `keyAlias`, `keyPassword`, `storeFile`, and `storePassword`, then run:

```bash
cd disc_golf_android
./gradlew :app:assembleRelease     # APK
./gradlew :app:bundleRelease       # AAB, what Play Console takes
```

Without `key.properties` the release build has no signing config and fails; use `:app:assembleDebug` for local unsigned testing.

CI builds the minified release bundle on every pull request
(`.github/workflows/release-build.yml`, job `release-build-check`), signed
with a throwaway key, so an R8 shrinking break fails CI instead of a release.
To produce the bundle you upload to Google Play, run that workflow manually:
its `signed-bundle` job signs with your upload key and attaches
`app-release.aab` to the run. It needs these repository secrets:

| Secret | Value |
|---|---|
| `RELEASE_KEYSTORE_BASE64` | The upload keystore, base64-encoded: `base64 -w0 upload.jks`. |
| `RELEASE_STORE_PASSWORD` | The keystore password. |
| `RELEASE_KEY_ALIAS` | The key's alias in the keystore. |
| `RELEASE_KEY_PASSWORD` | The key's password. |

No workflow reads the `ROBOFLOW_API_KEY` secret any more. Delete it from the
repository settings unless the flight tracking rebuild needs it.

### The public privacy policy

Google Play needs the privacy policy at a public URL.
`docs/privacy-policy.md` is that copy, ready to publish with GitHub Pages (or
anywhere else that serves Markdown or HTML). `PrivacyPolicyTest` fails when it
differs from the in-app text in `PrivacyPolicy.kt`, so change both together.

### Bumping the app version for a release

`versionCode` and `versionName` live in `disc_golf_android/app/build.gradle.kts`. **Increment `versionCode` on every release submitted to an app store**, even for a patch that only changes `versionName`: Google Play rejects a re-upload whose version code doesn't strictly increase over the previous release.

## Current next steps

1. **TODO: build and run the Kotlin client on a device.** The rewrite has
   been verified at the logic level — `:core`'s suite covers every ported
   calculation, and `:app`'s unit tests cover the Android-free helpers — but
   nothing here has exercised Compose, ML Kit, Media3, or
   `MediaMetadataRetriever` against a real device. Assemble a debug APK and
   walk each feature end to end; `docs/testing.md` has the checklist.
2. **Rebuild flight tracking.** Start from
   [Flight tracking rebuild reference](docs/flight-tracking-rebuild-reference.md).
3. Keep docs synchronized with source whenever assets, build settings, or
   runtime services change.
