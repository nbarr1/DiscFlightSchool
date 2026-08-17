# Google Play Console Submission & Android App Audit Report

**Target Repository / App:** `disc_golf_app` (Flutter, `com.discflightschool.app`)
**Audit Date:** 2026-08-14
**Audit Status:** ⚠️ **ACTION REQUIRED** (no hard manifest blockers found, but store-listing/compliance gaps will block submission or trigger takedown)

This audit mirrors the format and scope of TennisScoring's `play_store_readiness_report.md` audit, adapted to this repo's actual stack (Flutter/Android Gradle client + separate FastAPI training server), based on what is present in the repository today.

---

## Executive Summary

Unlike the TennisScoring mobile app, this codebase does **not** have the kind of manifest-level policy violations that block submission outright (no `SYSTEM_ALERT_WINDOW`, no unscoped legacy storage permission, permissions are already SDK-gated correctly). The client is a Flutter app with no login/account system, and its one clearly user-generated-content flow (opt-in training-sample uploads) is well-engineered: HTTPS-only enforcement, secure-storage-backed API keys, same-origin checks, and SHA-256 model verification.

The blocking gaps are almost entirely **compliance/store-listing gaps**, not code defects:

1. **No privacy policy anywhere** — no in-app screen, no public URL, nothing to enter in Play Console's mandatory Privacy Policy field despite the app requesting Camera, Microphone, and Photos/Video permissions and offering opt-in data upload to a first-party server plus optional pass-through to a third-party AI API (Anthropic).
2. **Two undisclosed third-party/first-party data flows** (training-sample image uploads, and BYO Anthropic API key for "AI Search") have no in-app disclosure text and would need explicit entries in Play Console's Data Safety form.
3. **`versionCode` is Flutter's default (`1`)** — fine for a first submission, but there's no documented process/reminder for incrementing it on every future release (the TennisScoring report flagged the same class of issue).
4. Release signing is gated correctly (Gradle throws if `key.properties` is missing for a release build) but **no keystore/CI signing pipeline exists yet** — nothing analogous to TennisScoring's EAS Credentials flow.
5. The Android manifest declares `CAMERA` even though the app never opens a live camera preview (no `camera` plugin — video capture goes through `image_picker`'s system camera intent). This is a real gotcha: `image_picker` treats a declared `CAMERA` permission as "this app manages the runtime prompt itself," so its absence would make the system camera intent Just Work without any prompt, while its presence (current state) requires the app to have already been granted `CAMERA` at runtime. This isn't a Play rejection, but it's worth confirming against the visible in-app string `"Could Not Open Camera. Check Camera Permission In Settings."`, which implies runtime-permission handling exists — this should be re-verified in a running build.
6. The training server (`server/`, deployed separately on Render per `_defaultServerUrl`) is out of Play Console's scope directly, but its behavior determines what the Data Safety form must say (see below), so it's covered here too.

---

## Detailed Audit Findings

### 1. Target API Level (SDK)

* **Status:** ✅ **PASS (once built with a current Flutter SDK)**
* **Analysis:**
  * `android/app/build.gradle.kts` does **not** hardcode `targetSdkVersion` — it delegates to `flutter.targetSdkVersion`, which Flutter's own Gradle plugin sets from the installed Flutter SDK/AGP version.
  * CI (`.github/workflows/build.yml`) pins `flutter-version: '3.x'` (floating), `compileSdk = 36`, NDK `27.0.12077973`. A `flutter-version: '3.x'` floating pin means the effective `targetSdkVersion` at build time is whatever the latest Flutter 3.x stable resolves to — this is likely to satisfy Google's current API-34+ requirement, but it is **not independently verified in this repo** since no `flutter` toolchain is available in this analysis environment (the repo's own `docs/phase1-audit.md` notes the same limitation).
  * **Recommendation:** Explicitly set `targetSdk = 35` in `android/app/build.gradle.kts` (matching what TennisScoring did in `1b87184 Target Android API level 35+ in mobile app build`) instead of relying on the Flutter plugin default, and pin the CI Flutter version instead of floating on `3.x` so a Flutter stable release doesn't silently change your target SDK out from under a release build.

---

### 2. Permissions & Security

* **Status:** ⚠️ **Action Needed** (no blockers, but undisclosed data flows)

#### Findings:

1. **Manifest permissions are already well-scoped** (`android/app/src/main/AndroidManifest.xml`):
   * `READ_EXTERNAL_STORAGE` / `WRITE_EXTERNAL_STORAGE` are correctly capped with `android:maxSdkVersion="32"`, with `READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO` declared for API 33+. This is exactly the fix TennisScoring's report demanded and DiscFlightSchool already has it right.
   * No `SYSTEM_ALERT_WINDOW`, no `MANAGE_EXTERNAL_STORAGE`.
   * `android:requestLegacyExternalStorage="true"` is present but inert on `targetSdk` ≥ 30 (harmless dead attribute — safe to remove for clarity, not required).
2. **`RECORD_AUDIO`** — declared and justified: the app records throw videos with audio (`video_player`/native camera intent), and `ios/Runner/Info.plist` has a matching `NSMicrophoneUsageDescription`. Unlike TennisScoring's flagged case, this is a legitimate, disclosed use — but it still needs a Data Safety entry (Audio data collected, not shared, app-functionality purpose) and, ideally, a short in-app rationale before first use.
3. **`CAMERA`** — declared, but no `camera`/`camerawesome` plugin is used anywhere in `lib/`; capture goes through `image_picker`'s `ACTION_IMAGE_CAPTURE` / `ACTION_VIDEO_CAPTURE` intents (see the `<queries>` block). Declaring `CAMERA` directly changes `image_picker`'s runtime-permission behavior on Android (it will require the permission be granted before invoking the system camera app, rather than letting the camera app manage its own permission). Verify this is intentional and that the observed error string (`flight_tracker_screen.dart:83`, "Could Not Open Camera. Check Camera Permission In Settings.") corresponds to an actual working runtime-permission prompt, not a dead/unreachable code path.
4. **`android:allowBackup`** is not set in the manifest at all → defaults to `true`. Given the app stores an Anthropic API key and a training-server API key in `flutter_secure_storage` (Android Keystore-backed, which is itself excluded from Auto Backup by default), this is lower risk than TennisScoring's case, but `SharedPreferences` (opt-in flag, server URL, model version) *is* backed up by default. Recommend setting `android:allowBackup="false"` or an explicit `android:dataExtractionRules`/`android:fullBackupContent` to be safe and consistent with TennisScoring's fix (`android:allowBackup="false"`).
5. **No `INTERNET`-adjacent network security config** (`res/xml/network_security_config.xml`) is present. Not required — the app already enforces HTTPS-or-localhost at the Dart layer (`TrainingDataService._isAllowedServerUri`) — but adding one that pins `usesCleartextTraffic="false"` would be defense-in-depth and costs nothing.

#### Undisclosed data flows (the real gap, not permissions):

* **Training-sample uploads** (`TrainingDataService.uploadPending()`): opt-in, uploads JPEG crops/full frames of the user's own throw videos plus YOLO labels to `https://discflightschool.onrender.com` (or a user-supplied server). This is collection of user-generated photo/video content by a first-party backend and **must** be declared in Play Console's Data Safety form (Photos/Videos — collected, not shared with third parties unless the backend forwards it, purpose: "App functionality"/"Analytics", user can request deletion via "Clear all training data" locally, but there's no way to request deletion of already-uploaded server-side copies — worth adding, see Recommendations).
* **Anthropic API pass-through** (`KnowledgeBaseService`, `training_settings_screen.dart` "AI Search"): the user supplies their own Anthropic API key, stored via `flutter_secure_storage`, and the app calls `https://api.anthropic.com/v1/messages` directly from the client with the user's search queries. This is a third-party data flow (search query text sent to Anthropic) and needs its own Data Safety disclosure, plus ideally a one-line in-app disclosure at the point the key is entered (currently the dialog only says the key is "used to query the Claude API for research answers," which is a reasonable start but doesn't mention this is a third-party service subject to Anthropic's own privacy terms).

---

### 3. App Bundle (.aab) & Build Pipeline

* **Status:** ⚠️ **Action Needed**
* **Analysis:**
  * `.github/workflows/build.yml` (`Build APK`) currently builds a **debug/unsigned APK**, not a release `.aab`. Google Play requires an Android App Bundle for new apps.
  * `android/app/build.gradle.kts` correctly throws a `GradleException` if a `release` task is selected without a complete `key.properties` (keyAlias/keyPassword/storeFile/storePassword) — good guardrail, directly analogous to what TennisScoring needed for EAS Credentials, but **no keystore exists yet and no CI job produces a signed release bundle.**
  * `isMinifyEnabled = false` / `isShrinkResources = false` in the `release` build type — fine for correctness, but means the release build gets no R8 shrinking/obfuscation. Not a Play blocker, but worth revisiting once release builds are actually happening (smaller download size, some protection against casual reverse engineering of the bundled `.tflite` model).
* **Recommendation:**
  * Add a release workflow (or extend `build.yml`) that runs `flutter build appbundle --release` using a securely-stored keystore (GitHub Secrets), producing the `.aab` Play Console needs — there is currently no equivalent to TennisScoring's `eas build --platform android --profile production` path.
  * Store the keystore + `key.properties` values as CI secrets, never commit them (confirm `key.properties` and `*.jks`/`*.keystore` are in `.gitignore` — verified present in `.gitignore`, good).

---

### 4. Versioning Strategy

* **Status:** ⚠️ **Action Needed**
* **Analysis:**
  * `pubspec.yaml` declares `version: 1.0.0+1` → Flutter derives `versionName=1.0.0`, `versionCode=1` for both platforms from this single field (`android/app/build.gradle.kts` reads `flutter.versionCode`/`flutter.versionName`, no manual override).
  * This is fine for the *first* submission, but there is no CI check or documented convention (unlike TennisScoring's explicit versioning section in `CLAUDE.md`) ensuring the `+N` build-number suffix is bumped on every subsequent release — Play Console rejects a re-upload with a duplicate `versionCode`.
* **Recommendation:** Document the "bump `pubspec.yaml`'s `+build` number every release" rule (e.g. in `README.md` or a `CLAUDE.md`/`AGENTS.md` if one gets added) and/or add a CI check that fails if a tagged release doesn't bump the build number.

---

### 5. Privacy Policy & Compliance

* **Status:** 🛑 **BLOCKER**
* **Analysis:**
  * No privacy policy exists anywhere in this repository — no in-app screen (unlike TennisScoring's shared `packages/shared/src/legal/privacyPolicy.ts` rendered on both mobile and web), no `docs/` page, no URL referenced in `README.md`, `pubspec.yaml`, or any screen's source.
  * Google Play Console's **App Content → Privacy Policy** field is mandatory for every app and is checked at submission; it is doubly mandatory here because the app requests `CAMERA`/`RECORD_AUDIO`/photo-library access and has two real data-collection flows (training uploads, Anthropic pass-through) described above.
  * There is also no in-app Settings/About surface that links out to legal information (`lib/screens/settings/` currently contains only `training_settings_screen.dart` — no general Settings or About screen).
* **Fix:** Before submission:
  1. Write a privacy policy covering: what's collected (camera/mic/photo access — used locally by default; opt-in training image uploads to the DiscFlightSchool server; user-supplied Anthropic API key and search-query pass-through to Anthropic), retention/deletion (note the app-side "Clear all training data" only clears local data — decide and document whether/how a user can request deletion of already-uploaded server-side samples), and contact info.
  2. Host it at a stable public URL (e.g., a GitHub Pages page off this repo, or a simple static page on the same Render account hosting the training server) and enter that URL in Play Console.
  3. Add an in-app link to it (a Settings/About screen, or a footer link on the existing `training_settings_screen.dart`), matching what TennisScoring did with its dedicated privacy-policy screen.

---

### 6. Data Safety Form Declarations (Play Console)

* **Status:** ⚠️ **Action Needed**
* Based on what the code actually does, the Data Safety form should declare:
  * **Photos and videos** — collected (training uploads, opt-in), processed on-device by default (pose detection via `google_mlkit_pose_detection`, disc detection via bundled `tflite_flutter` model — both on-device, not sent anywhere unless the user opts in).
  * **Audio** — collected as part of recorded throw videos (justified by `RECORD_AUDIO` + iOS `NSMicrophoneUsageDescription`).
  * **App activity / search terms** — sent to a third party (Anthropic) only if/when the user adds their own API key and uses "AI Search."
  * No account/identity data is collected — the app has no login system, which meaningfully reduces scope here versus TennisScoring (which has Firebase Auth, FCM tokens, messaging, etc.).
  * Data is **not encrypted in transit** by default only in the trivial sense that `_isAllowedServerUri` also permits plain `http://localhost`/`127.0.0.1`/`::1` — that's a developer-mode allowance, not reachable from a real device pointed at production, so it doesn't affect the Data Safety answer, but confirm the shipped default (`https://discflightschool.onrender.com`) is what ends up in the build.

---

### 7. Server-Side Considerations (`server/`, not itself a Play Console artifact but shapes the Data Safety answers)

* **Status:** ℹ️ **Informational**
* `server/training_server/app.py` requires `X-App-Key` (an `APP_API_KEY` env var, checked via `hmac.compare_digest`-style constant-time comparison per the audit docs) for upload/export/start endpoints — reasonable baseline auth for a single-tenant training backend.
* CORS (`cors_allow_origins`) is configurable, not hardcoded to `*` — good.
* Per `README.md`, Postgres/Redis/MinIO are provisioned in `docker-compose.yml` but **not actually used by any implemented adapter** — filesystem storage is the only backend live today. This is a correctness/architecture note more than a Play Store issue, but it means uploaded user images currently live as plain files on the Render instance's disk with no described retention/expiry policy — this detail belongs in the privacy policy (§5) once written.
* `server/.env.example` exists (good — no secrets committed); confirm `APP_API_KEY` used in production is never the same value distributed to any client build.

---

## Action Checklist (Pre-Submission Checklist)

### 🚨 Blockers (Must Fix Before Submission)
- [ ] **Write and publish a Privacy Policy** covering camera/mic/photo use, opt-in training-image uploads, and the Anthropic pass-through; add the URL to Play Console → App Content.
- [ ] **Add an in-app link** to the privacy policy (new Settings/About screen, or append to `training_settings_screen.dart`).
- [ ] **Complete the Data Safety form** for Photos/Videos, Audio, and App Activity (search terms) per §6 above.

### ⚠️ High Priority
- [ ] **Explicitly pin `targetSdk = 35`** in `android/app/build.gradle.kts` instead of relying on Flutter's floating default; pin the CI `flutter-version` to match.
- [ ] **Add a signed release `.aab` CI pipeline** (`flutter build appbundle --release` + keystore secrets) — none exists today; `build.yml` only produces a debug APK.
- [ ] **Set `android:allowBackup="false"`** (or explicit backup rules) given the app persists a server URL/opt-in flag via `SharedPreferences`.
- [ ] **Verify the `CAMERA` permission's actual runtime-prompt behavior** against `image_picker`'s documented interaction — confirm the observed "Check Camera Permission In Settings" path is reachable and correct in a real build, and remove the permission if it turns out to be unnecessary.
- [ ] **Document the `pubspec.yaml` build-number bump convention** for future releases (currently `1.0.0+1`, fine for the first submission only).

### 📋 Final Quality Assurance
- [ ] Run `flutter analyze` and `flutter test` in an environment with the Flutter/Android toolchain installed (not available in this audit environment — `docs/phase1-audit.md` flags the same gap).
- [ ] Build and sign a real `.aab` via `flutter build appbundle --release`, then test it through Google Play **Internal Testing** on an API 34+ device.
- [ ] Manually verify the Camera/Microphone/Photos runtime permission prompts show sensible rationale on first use.
- [ ] Manually verify the opt-in toggle in Training Settings actually gates the upload flow end-to-end, and that "Clear all training data" behaves as the privacy policy will describe.
- [ ] Confirm the shipped build's default training server URL (`https://discflightschool.onrender.com`) is the intended production endpoint and is reachable/healthy at submission time.

---

## Comparison to TennisScoring's Audit

| Area | TennisScoring (Expo/RN) | DiscFlightSchool (Flutter) |
|---|---|---|
| Manifest permission hygiene | 🛑 Blocker (`SYSTEM_ALERT_WINDOW`, broad storage perms) | ✅ Already scoped correctly |
| `allowBackup` | 🛑 Defaulted `true`, fixed | ⚠️ Still defaults `true` — not yet fixed |
| Privacy policy | ✅ Added (shared package, mobile + web) | 🛑 Missing entirely |
| Target SDK | ⚠️ Unverified → fixed to 35 in a follow-up PR | ⚠️ Relies on Flutter's floating default, unpinned |
| Signed release pipeline | ✅ EAS Credentials / `eas build` | 🛑 No signed `.aab` CI job yet |
| Account/identity data | Firebase Auth, FCM, messaging — broad surface | None — no login system, smaller surface |
| UGC moderation (report/block) | Added for chat messages | N/A — no chat/social features |
| Third-party data pass-through | N/A | Anthropic API key (BYOK), undisclosed |
