# Remediation Plan: Google Play Readiness Findings

Companion to `docs/google-play-readiness-report.md`. Each item below maps 1:1 to a finding in that report, ordered by priority, with the concrete files to touch, and a note on whether it's something this repo/agent can execute directly or whether it needs an action only the app owner can take (Play Console access, a real signing keystore, legal sign-off on policy text).

Status legend: 🔧 code/config change (agent-executable) · 🔑 needs owner-supplied secret/credential · 🧑‍⚖️ needs owner decision or Play Console access · 🧪 needs a real device/toolchain to verify.

**Status update (2026-08-19):** all 🔧 items below have shipped except the
public privacy-policy URL decision (still 🧑‍⚖️) and the release-signing
pipeline scaffold (blocked on 🔑 keystore secrets). Each completed item is
marked ✅ below; the rest are still open exactly as originally scoped.

---

## Phase 1 — Blockers

### 1.1 Write and ship a Privacy Policy — ✅ in-app parts done, 🧑‍⚖️ public URL still open
- 🔧 Draft policy content as a single source of truth, following TennisScoring's pattern (`packages/shared/src/legal/privacyPolicy.ts`) of one canonical copy reused everywhere. Given this repo has no shared package, put it in `disc_golf_app/lib/legal/privacy_policy.dart` as plain constants (title/sections/last-updated), so a future web/static page can reuse the same strings if one gets added.
  - Cover: camera/mic/photo access (used locally by default), opt-in training-image uploads to `discflightschool.onrender.com` (or user-configured server), the Anthropic API key pass-through and what data leaves the device when it's used, local data retention (what "Clear all training data" does and doesn't clear — it's local-only, uploaded copies persist server-side), and a contact method.
- 🔧 Add an in-app screen, `lib/screens/settings/privacy_policy_screen.dart`, rendering those constants, and link to it from `training_settings_screen.dart` (or a new general Settings/About entry if one gets added — see 4.1).
- 🧑‍⚖️ Decide and stand up a **public URL** for the policy (required for the Play Console field, separate from the in-app screen). Options, cheapest first:
  1. A static page served by the existing FastAPI server (`server/training_server/app.py` already has unauthenticated `GET` routes — add `GET /privacy` returning the same text as HTML).
  2. GitHub Pages off this repo.
  - This step needs an owner decision (which hosting option) before it can be implemented; flagging rather than picking one, since it affects the server's threat surface differently.
- 🧑‍⚖️ Enter the chosen URL into Play Console → App Content → Privacy Policy (Console access, not code).

### 1.2 Complete the Data Safety form — still open (Play Console)
- 🧑‍⚖️ Play Console UI task, not a code change. Use the "Data Safety Form Declarations" section of the audit report as the answer key (Photos/Videos — collected, app functionality purpose; Audio — collected, justified by RECORD_AUDIO; App activity/search terms — shared with Anthropic only when AI Search is used; no account/identity data).
- 🔧 Optional but recommended: turn that same answer key into a short `docs/data-safety-answers.md` checklist so it's reproducible on every future Data Safety re-certification (Play requires periodic reconfirmation), and stays in sync automatically if a future PR adds a new data flow (add a rule of thumb: "new `http`/API call touching user content → update this doc").

---

## Phase 2 — High Priority

### 2.1 Pin `targetSdk` explicitly — ✅ done
- 🔧 `disc_golf_app/android/app/build.gradle.kts`: change `targetSdk = flutter.targetSdkVersion` to `targetSdk = 35` (matching TennisScoring's `1b87184` fix). Leave `compileSdk = 36` as-is.
- 🔧 `.github/workflows/build.yml` and `.github/workflows/flutter-tests.yml`: change `flutter-version: '3.x'` to an exact pinned version (e.g. `'3.35.0'` — pick whatever the team is actually developing against locally) so a new Flutter stable release can't silently change build output between runs.
- 🧪 Needs a Flutter/Android toolchain to confirm the app still builds and runs correctly at API 35 — not verifiable in this analysis environment; should be the first thing checked once a toolchain is available.

### 2.2 Signed release `.aab` CI pipeline — still open (🔑 needs a keystore)
- 🔧 Add `.github/workflows/release.yml` (or extend `build.yml` with a second job) that runs `flutter build appbundle --release`, decoding a base64-encoded keystore from a GitHub secret into `android/app/upload-keystore.jks` and writing `android/key.properties` from secrets before the build step (mirrors what the existing `key.properties` Gradle guard already expects).
- 🔑 **Needs the owner to generate a real upload keystore** (`keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload`) and add it plus its passwords as GitHub Actions secrets (`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, `ANDROID_STORE_PASSWORD`). This can't be generated on the app's behalf — a lost/regenerated keystore breaks the ability to publish updates to an already-live app, so this has to be created and custodied by the owner, not by an agent.
- 🔧 Document the secret names and setup steps in `README.md` or `SETUP.md` (if one gets added) once the workflow exists, so the process is repeatable.

### 2.3 `android:allowBackup="false"` — ✅ done
- 🔧 `disc_golf_app/android/app/src/main/AndroidManifest.xml`: add `android:allowBackup="false"` to the `<application>` tag (same fix TennisScoring applied). One-line change, no dependencies — do this immediately, independent of the other phases.

### 2.4 Verify the `CAMERA` permission's actual behavior — still open (🧪 needs a device)
- 🧪 Needs a real device/emulator: build a debug APK, exercise the "record a throw" flow via `flight_tracker_screen.dart`, and confirm whether removing the declared `CAMERA` permission changes `image_picker`'s prompt behavior for the better (Android-only concern; iOS is unaffected since `NSCameraUsageDescription` already exists and iOS doesn't have this manifest-permission interaction).
- 🔧 Once verified: either remove `<uses-permission android:name="android.permission.CAMERA"/>` from the manifest if it turns out to be unnecessary, or, if it is needed, add a short in-app rationale immediately before the first camera-triggering action (a one-line `SnackBar` or dialog), consistent with Play's runtime-permission best practices.

### 2.5 Document the version-bump convention — ✅ done (root `README.md`)
- 🔧 Add a short section to `README.md` (or a new `CLAUDE.md`/`AGENTS.md` if this repo adopts one) stating: bump the `+build` suffix in `disc_golf_app/pubspec.yaml`'s `version:` field on every release, since Play Console rejects a re-upload with a duplicate `versionCode`. Low effort, prevents a real future submission failure.

---

## Phase 3 — Also worth doing (not blockers, cheap now)

### 3.1 Remove dead `android:requestLegacyExternalStorage="true"` — ✅ done
- 🔧 `AndroidManifest.xml` — inert at the pinned `targetSdk = 35` from 2.1; delete for clarity. Bundle with 2.3 since it's the same file/PR.

### 3.2 Network security config (defense in depth) — ✅ done
- 🔧 Add `disc_golf_app/android/app/src/main/res/xml/network_security_config.xml` with `cleartextTrafficPermitted="false"` for the base config, and reference it via `android:networkSecurityConfig` on the `<application>` tag. The Dart-layer `_isAllowedServerUri` check already enforces this logically; this makes it enforced at the OS level too, in case any dependency (ffmpeg_kit, tflite_flutter, mlkit) ever makes a stray plain-HTTP call outside that guarded path.

### 3.3 Improve the Anthropic API key dialog disclosure — ✅ done
- 🔧 `lib/screens/settings/training_settings_screen.dart`, `_showApiKeyDialog`: extend the existing text ("Your key is stored in platform secure storage and is only used to query the Claude API for research answers.") to explicitly note that search queries are sent to Anthropic, a third-party service subject to Anthropic's own privacy terms — one sentence, links the in-app disclosure to what the privacy policy (1.1) will describe.

### 3.4 Server-side retention/deletion story — ✅ documented (no deletion endpoint; policy explains why)
- 🧑‍⚖️ Decide whether uploaded training images should have a retention limit or a way for a user to request deletion of already-uploaded samples (the app can already clear local copies via "Clear all training data," but has no way to reach already-uploaded server-side copies). This is a product decision, not just code — once decided:
- 🔧 If a deletion path is wanted: add a `DELETE /api/training/samples/{sample_id}` (or similar) endpoint to `server/training_server/app.py`, and a corresponding call from `TrainingDataService`. Otherwise, just document the "no deletion, images are used to train future model versions" policy explicitly in 1.1's privacy policy text so it's not silently missing.

---

## Suggested execution order

1. **Now, no dependencies:** 2.3 (`allowBackup`), 3.1 (dead attribute) — same file, one PR.
2. **Now, no dependencies:** 2.1's `targetSdk` pin + CI Flutter version pin.
3. **Now, no dependencies:** 1.1's in-app privacy policy screen + constants (content can be drafted even before the hosting/URL decision in the same step is finalized — ship the in-app screen, follow up with the public URL once hosting is chosen).
4. **Needs your input:** pick a hosting option for the public policy URL (1.1) → then wire up `GET /privacy` or GitHub Pages.
5. **Needs your input:** generate and hand over keystore secrets for 2.2's signed-release pipeline.
6. **Needs Play Console access:** 1.2 (Data Safety form), plugging in the URL from step 4.
7. **Needs a toolchain/device:** 2.4 (camera permission verification), final QA pass from the original report's checklist.

Items 1–3 (and 3.2/3.3, which are equally dependency-free) can be implemented directly in this repo without any input from you. Say the word and I'll start on those; items 4–7 need a decision or credentials only you can provide.
