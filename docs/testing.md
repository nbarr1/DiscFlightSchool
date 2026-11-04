# Testing

## Running the suites

```bash
./scripts/test_android.sh          # :core:test + :app:testDebugUnitTest
```

`:core` is a plain Kotlin/JVM module, so `./gradlew :core:test` alone needs
nothing but a JDK 17 — no Android SDK.

CI runs them on every pull request (`.github/workflows/android-tests.yml`,
which also runs Android Lint), and `release-build.yml` builds the minified
release bundle.

## Android coverage

Everything ported out of Dart that can be tested without a device lives in
`:core`, which is why the suite concentrates there.

| File | Covers |
|---|---|
| `AngleCalculatorTest.kt` | 2-D/3-D joint angles, X-factor sign and magnitude, Catmull-Rom control-point interpolation, anchor filling |
| `ScoringRepositoryTest.kt` | round persistence (including the undo/re-enter duplicate-save regression), corrupt-store resilience, statistics |
| `PostureMathTest.kt` | lead/trail knee labelling per throw type, physiological-limit clamping vs dropping, angle and keypoint smoothing, pro deviation scoring |
| `KnowledgeSearchTest.kt` | local keyword search: tokenizing, ranking, source citations, and the no-keyword and no-match messages |
| `RouletteTest.kt` | disc/power/shape generation, incompatible-combination filtering, difficulty weighting |
| `FrameSamplingTest.kt` | which timestamps a trimmed clip is sampled at: the trim start, the span, the frame cap, and the clip duration |
| `DataContractsTest.kt` | the persisted formats — landmark keys, ISO timestamps, legacy fields — that an upgrading install still has to read |

`:app`'s own unit tests cover the helpers that are Android-free but live in the
Android module: `FormattingTest.kt` (scorecard and history readouts),
`FrameIndexTest.kt` and `FrameForFractionTest.kt` (timestamp-to-frame maths),
and `PrivacyPolicyTest.kt` (the in-app policy matches `docs/privacy-policy.md`).

### What these tests deliberately do not cover

A JVM unit test cannot exercise anything that needs a real Android framework or
native library. The following are **not** covered and still need a device or
emulator:

- `PostureAnalyzer.analyze()` — needs ML Kit pose detection.
- Every Compose screen, and the navigation graph wiring them together.
- `EncryptedSharedPreferences` reads and writes, which fall back to an
  in-memory store when the keystore is unavailable.

### TODO: walk the app on a device

The Kotlin client has never been run. Assemble a debug APK and go through each
feature once, watching for the things a unit test cannot see: permission
prompts, video pickers returning a content URI the app has to copy, playback
seeking landing on the frame the analysis measured, and state surviving a
rotation or a trip through the background.
