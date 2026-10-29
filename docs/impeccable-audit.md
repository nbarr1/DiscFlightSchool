# Impeccable technical audit

This document records an Impeccable `audit` of the Disc Flight School Android app, run on October 29, 2026 against `main` at commit `bf49327`. It follows the native audit in the Impeccable skill (`skill/reference/audit.native.md`) and scores the app against that skill's Android reference (`skill/reference/android.md`).

The audit is report-only. It doesn't change any code. The earlier polish pass, recorded in [design-audit.md](design-audit.md), fixed the Back handling, button hierarchy, empty states, and readable-width issues it found. Those fixes are treated as the baseline here, and they aren't repeated as findings.

## Scope and method

The audit covers the Compose UI in `disc_golf_android/app` (about 30 screens and shared components). The `server/` service has no user interface. There is no `PRODUCT.md` or `DESIGN.md`, so the audit has no recorded audience or brand intent to check against.

The audit is from source only. The app wasn't built or run, so nothing here comes from an emulator or a device. Contrast ratios were computed from the hex values in `ui/theme/Theme.kt` with the WCAG 2.x relative-luminance formula. Findings that depend on runtime behavior (keyboard, landscape, font scale) are marked "likely" and need a device check before a fix.

The scores use the Impeccable native rubric, which has different dimensions from the earlier pass. The two sets of scores aren't directly comparable.

## Audit health score

The following table scores each dimension from 0 to 4.

| # | Dimension | Score | Key finding |
|---|---|---|---|
| 1 | Accessibility | 2 | Outline borders at 1.65:1 app-wide, purple and score colors below 4.5:1, and the core marking canvases have no TalkBack path. |
| 2 | Performance | 3 | Frame work is off the main thread, and thumbnails decode at reduced size. Lists lack stable keys. |
| 3 | Appearance and theming | 2 | A palette exists, but screens read `AppColors` 264 times and `MaterialTheme.colorScheme` twice. |
| 4 | Platform conformance | 3 | Material components and system Back throughout. Predictive Back isn't opted in, and keyboard insets are handled on one screen. |
| 5 | Adaptivity | 2 | Video screens stack fixed control bars under a weighted video, which likely collapses in landscape. |
| **Total** | | **12/20** | **Acceptable (significant work needed)** |

## Platform conformance verdict

Pass. The app reads as a native Android app, not a ported website. Every screen uses the shared Material 3 `TopAppBar`, Material buttons in filled, tonal, and outlined roles, Material dialogs and bottom sheets, snackbars (no toasts), and one icon set (Material filled icons, with a single outlined `Info`). System Back closes sheets, dialogs, and players, and edge-to-edge layout is in place.

The gaps are at the edges of the platform contract, not in its structure:

- Predictive Back isn't opted in.
- Keyboard (IME) insets are applied on one of six screens with text fields.
- The theme bypasses Material color roles in screen code.

## Executive summary

The audit found 13 issues: no P0, four P1, six P2, and three P3.

The top issues are the following:

1. The outline color fails non-text contrast, so every outlined text field and outlined button has a barely visible border (P1).
2. The Roulette purple and the scorecard's score colors fail text contrast (P1).
3. Text fields on five screens likely sit under the keyboard, because edge-to-edge disables the window resize that `adjustResize` relies on (P1).
4. The flight player and pose correction screens likely lose most of the video area in landscape (P1).
5. Marking points, dragging joints, and seeking the angle waveform work only by touch, with no TalkBack alternative (P2, noted as a known gap in the earlier pass).

The recommended next steps are to fix the two contrast tokens in `Theme.kt`, which removes most of the accessibility findings in one change, and then to check the keyboard and landscape findings on a device.

## Detailed findings by severity

### P1: major

#### [P1] Outline color fails non-text contrast

- **Location:** `ui/theme/Theme.kt:50` (`outline = Color(0xFF38455F)`). This affects every `OutlinedTextField` (seven, on six screens) and every `OutlinedButton`.
- **Category:** Accessibility
- **Impact:** The outline is 1.65:1 against `surface` and 1.77:1 against `background`. WCAG 1.4.11 asks for 3:1 for the boundary of an input. Text fields and outlined buttons, including the outlined Clear button, are hard to find for users with low vision or in sunlight, which is where a disc golf app is used.
- **Guideline:** WCAG 2.2 SC 1.4.11 (non-text contrast). Material color roles: `outline` is meant for "important boundaries" such as text field borders, and `outlineVariant` is the low-contrast decorative role.
- **Recommendation:** Raise `outline` to at least 3:1 against `surface` (a value near `#6B7A99` is in range, to be checked). Add an `outlineVariant` set to today's `#38455F` for dividers.
- **Suggested command:** `/impeccable colorize`

#### [P1] Roulette purple and score colors fail text contrast

- **Location:**
  - `ui/theme/Theme.kt:27` (`AppColors.Roulette = #AB47BC`).
  - `screens/roulette/RouletteScreen.kt:241` ("Throwing mode" label in purple).
  - `screens/roulette/ScorecardScreen.kt:256-262` (score-to-par chip, `Background` text on the chip color).
  - `screens/roulette/ScorecardScreen.kt:312-336` (`HoleTile` strokes in the score color over a 20% tint of the same color).
  - `screens/roulette/PlayRoundScreen.kt:721` (`scoreColor`).
- **Category:** Accessibility
- **Impact:** The computed ratios are the following:
  - Purple text on `surface` is 3.30:1.
  - Dark text on an eagle (purple) chip is 3.54:1.
  - Eagle strokes on their tile are 2.72:1.
  - Double-bogey (red) strokes on their tile are 3.65:1.

  All of these are normal-size bold text, which needs 4.5:1. The scorecard is the screen where people read these numbers at a glance outdoors.
- **Guideline:** WCAG 2.2 SC 1.4.3 (contrast minimum).
- **Recommendation:** Keep the hues, but use a lighter tone for text (for example, a purple near `#CE93D8`, and the same treatment for `Bad`). Draw tile numbers in `OnSurface` and keep the score color for the tile border and tint, so the meaning doesn't rest on a low-contrast foreground.
- **Suggested command:** `/impeccable colorize`

#### [P1] Keyboard likely covers text fields (likely, needs a device check)

- **Location:** `MainActivity.kt:39-55` and `AndroidManifest.xml:41`. Affected fields are in the following places:
  - `screens/formcoach/FormCoachScreen.kt:194`
  - `screens/formcoach/PostureAnalysisScreen.kt:383`
  - `screens/settings/TrainingSettingsScreen.kt:397`
  - `screens/roulette/StartRoundScreen.kt:117`
  - `screens/roulette/PlayRoundScreen.kt:378`
- **Category:** Platform conformance and adaptivity
- **Impact:** The activity calls `enableEdgeToEdge()` and relies on `android:windowSoftInputMode="adjustResize"`. In edge-to-edge mode, the window no longer resizes for the keyboard, and the app must apply IME insets itself. Only `ResearchSearchScreen` applies `imePadding()`. On the other screens, a focused field near the bottom of a scrolling column can stay under the keyboard, and the player-name fields in round setup are the most likely case.
- **Guideline:** Android reference: "Apply the status bar, navigation bar, display cutout, and IME insets so content never hides behind system bars or the keyboard."
- **Recommendation:** Apply `imePadding()` once at the root `Surface` in `MainActivity`, next to the existing navigation-bar inset, and remove the per-screen one. Then check each field on a device with the keyboard open.
- **Suggested command:** `/impeccable adapt`

#### [P1] Video screens likely collapse in landscape (likely, needs a device check)

- **Location:**
  - `screens/flighttracker/FlightPlayerScreen.kt:619-760` (video `weight(1f)`, then `StatsBar`, `PlaybackBar`, and `ActionBar`).
  - `screens/formcoach/PoseCorrectionScreen.kt:329-339`.
  - `screens/formcoach/VideoTrimScreen.kt:137-219`.
- **Category:** Adaptivity
- **Impact:** These screens put the video in a weighted box and stack fixed-height control bars under it, with no scroll. The manifest doesn't lock orientation. On a phone in landscape, the usable height after the top bar is roughly 300dp, and the control bars alone likely take most of it, which leaves the video, where the user taps the disc, only a thin strip. These are the app's core tasks.
- **Guideline:** Android reference: "Orientation breakage: landscape clipping, ignored, or locked without reason."
- **Recommendation:** On a wide, short window, put the controls in a side column next to the video. As an alternative, lock these screens to portrait with a stated reason. Use `currentWindowAdaptiveInfo()` or `BoxWithConstraints` to switch layouts.
- **Suggested command:** `/impeccable adapt`

### P2: minor

#### [P2] Touch-only canvases have no TalkBack path

- **Location:**
  - Point marking: `screens/flighttracker/FlightPlayerScreen.kt:643`.
  - Joint dragging: `screens/formcoach/PoseCorrectionScreen.kt:348-393`.
  - Tap-to-seek: `ui/components/AngleWaveform.kt:37`.
  - Trend chart: `screens/formcoach/FormHistoryScreen.kt:171`.
- **Category:** Accessibility
- **Impact:** None of the canvases expose semantics. Marking a disc in a video is inherently visual, but the waveform and the trend chart carry information (angles over time, score trend) that TalkBack users get nothing of. The waveform's seek action is unreachable for them. The earlier pass notes this as a remaining gap.
- **Guideline:** Android reference: "Missing labels: interactive elements without accessibility labels, traits/roles, or state announcements."
- **Recommendation:** Give each chart a `contentDescription` that summarizes it (for example, "Score trend over 8 sessions, latest 7.4"). Give the waveform `customActions` for next and previous phase. On the marking canvases, label the canvas with what it's for, and point to the frame step buttons as the non-touch route.
- **Suggested command:** `/impeccable harden`

#### [P2] Screen code bypasses Material color roles

- **Location:** This pattern is app-wide. There are 264 `AppColors.` reads in `ui/`, 2 `MaterialTheme.colorScheme` reads, 7 raw hex colors outside the theme (`RouletteScreen.kt:350-377`, `FlightPlayerScreen.kt:1106`, `FlightPathOverlay.kt:203-205`), and 64 `Color.White`, `Color.Black`, and similar constants.
- **Category:** Appearance and theming
- **Impact:** The palette is defined once, which is good, but screens read the raw palette instead of roles. Changing a role in the scheme (for example, the outline fix earlier in this document) doesn't reach custom components that hard-code `AppColors.Surface` or `AppColors.Muted`. Many of the white and black constants are text over video, which is a legitimate fixed case. Those are the ones to keep.
- **Guideline:** Android reference: "Material color roles. Role tokens resolve light/dark and contrast variants automatically; raw hex breaks there."
- **Recommendation:** Map `Muted` to `onSurfaceVariant`, `Surface` to `surface` or `surfaceContainer`, and `TopBar` to `primaryContainer` at the call sites. Keep `AppColors` only for the per-feature accents and status colors, and move the wheel and trail hex values into named constants in the theme.
- **Suggested command:** `/impeccable extract`

#### [P2] Predictive Back isn't opted in

- **Location:** `AndroidManifest.xml:23` (no `android:enableOnBackInvokedCallback`).
- **Category:** Platform conformance
- **Impact:** Back works on every screen, but the system's predictive back-to-home and cross-activity preview doesn't play, so the app feels a step behind other apps on Android 14 and later. Raising `targetSdk` (it's 34 today) is likely to make the predictive behavior the default, so it's worth testing before that change rather than after.
- **Guideline:** Android reference: "Honor the predictive Back gesture and Back button; never trap the user or hijack the gesture."
- **Recommendation:** Add `android:enableOnBackInvokedCallback="true"` to the `<application>` tag. Then walk the `BackHandler` flows in `FlightTrackerScreen`, `VideoGalleryScreen`, and `PoseCorrectionScreen`, because those intercept Back on purpose.
- **Suggested command:** `/impeccable polish`

#### [P2] Fixed-size score badges likely clip at large font sizes (likely)

- **Location:** `screens/formcoach/FormHistoryScreen.kt:223` (a 56dp circle holding two lines of text). The 60dp and 80dp chart rows at `FormHistoryScreen.kt:147` and `PostureAnalysisScreen.kt:811` hold no text, so they're fine.
- **Category:** Accessibility
- **Impact:** At a font scale of 1.5 or more, the score and its caption likely overflow the fixed circle. The app uses no fixed `sp` sizes anywhere, which is good, so this is the one place the type scale meets a fixed box.
- **Guideline:** Android reference: "sp units, never fixed px, so type follows the system font-size setting." Also "layouts that clip or overlap at large sizes."
- **Recommendation:** Use `defaultMinSize` instead of `size`, or drop the caption line in the circle when the font scale is large.
- **Suggested command:** `/impeccable harden`

#### [P2] No layout change for tablets beyond a width cap

- **Location:** `ui/components/Common.kt` (`readableWidth`), applied app-wide.
- **Category:** Adaptivity
- **Impact:** The 640dp readable column from the earlier pass stops the stretching, but a tablet still shows a centered phone column with wide empty margins. List-detail flows (knowledge base category to article, form history to session) are the natural two-pane candidates.
- **Guideline:** Android reference: "Never ship a phone bottom-bar untouched on a tablet." Also "Stretched phone layouts."
- **Recommendation:** Only a P2 if tablets are a target for the Play listing. Use `ListDetailPaneScaffold` for the knowledge base first, since it's read-only and low-risk.
- **Suggested command:** `/impeccable adapt`

#### [P2] Lists have no stable keys

- **Location:**
  - `PhaseComparisonScreen.kt:119`
  - `PhaseFrameSelectorScreen.kt:254`
  - `KnowledgeBaseScreen.kt:122`
  - `RouletteHistoryScreen.kt:89`
  - `StartRoundScreen.kt:199`
  - `ScorecardScreen.kt:286`
- **Category:** Performance
- **Impact:** All six use `items(count)` or `items(list)` without `key`. The lists are short, so scrolling cost is small. The visible effect is on lists that change (roulette history, round setup), where item state and animations can attach to the wrong row after an insert or delete.
- **Recommendation:** Pass `key = { it.id }` (or the hole number or player name) on the changing lists.
- **Suggested command:** `/impeccable optimize`

### P3: polish

- **[P3] The Remove animations check doesn't update.** `rememberReduceMotion()` in `Common.kt:269` reads the setting once per composition context, so changing it while the app is open has no effect until the screen is recreated. Because the manifest handles configuration changes itself, that can mean until the process restarts. Suggested command: `/impeccable polish`.
- **[P3] The home cards use the rounded-square icon tile.** `NavigationCard` puts each feature icon in a tinted rounded square next to the title. Impeccable's README names "the rounded-square icon tile above every heading" as a generic tell. It's mild here (four cards, one screen), but it's the app's first impression. This is a judgment call for a `critique` run, not a defect. Suggested command: `/impeccable critique`.
- **[P3] No product context file.** There's no `PRODUCT.md`, so later Impeccable runs can't check copy, tone, or priorities against a stated audience. The earlier pass flagged the same gap. Suggested command: `/impeccable init`.

## Patterns and systemic issues

The following patterns recur across screens:

- **Two theme tokens cause most of the accessibility findings.** The `outline` value and the `Roulette` accent fail contrast, and both are used app-wide. Fixing them in `Theme.kt` fixes every screen at once.
- **The palette is read raw, not through roles.** With 264 direct `AppColors` reads, theme changes don't propagate. This is the reason the token fixes need call-site checks.
- **Window insets are handled per screen.** The navigation-bar inset is central, but the IME inset isn't. Insets belong in one place.
- **Video screens assume portrait.** All three video-editing screens use the same weighted-video-over-controls layout.

## Positive findings

The following practices are worth keeping and replicating:

- **There are no fixed `sp` sizes.** All text uses Material type scale roles, so system font size flows through.
- **Every interactive icon has a label.** The 81 `contentDescription = null` cases checked are decorative icons next to a text label.
- **Heavy work is off the main thread.** `FrameExtractor` runs on `Dispatchers.IO`, and gallery thumbnails decode with `inSampleSize`.
- **The app uses one icon set and one top bar.** Every screen goes through `AppTopBar` and Material filled icons.
- **Feedback uses Material components.** Snackbars (with Undo) handle transient feedback, dialogs are reserved for decisions, and no toasts are used.
- **The dark-only theme is a stated decision.** `Theme.kt` explains that overlays on video need dark chrome. Skipping light mode and Dynamic Color is a deliberate product choice, not an oversight, so it isn't scored as a defect.
- **No nested cards were found.** A scan for cards inside `SectionCard` or `Card` found none.

## Recommended actions

The following commands are listed in priority order:

1. **[P1] `/impeccable colorize`:** Fix the `outline` and `Roulette` tokens and the score colors in `Theme.kt` and `scoreColor`, and draw hole-tile numbers in `OnSurface`.
2. **[P1] `/impeccable adapt`:** Apply IME insets at the root, and give the three video screens a landscape layout or a reasoned portrait lock. Check both on a device.
3. **[P2] `/impeccable harden`:** Add semantics to the charts and waveform, and let the history score badge grow with font size.
4. **[P2] `/impeccable extract`:** Move screen code from `AppColors` to color roles, keeping accents and status colors as named tokens.
5. **[P2] `/impeccable optimize`:** Add stable keys to the changing lists.
6. **[P3] `/impeccable init`:** Write `PRODUCT.md` so later runs have product context.
7. **`/impeccable polish`:** Opt in to predictive Back, make the reduce-motion check update, and do a final pass.

Re-run `/impeccable audit` after the fixes to compare scores.

## Fixes applied

The fixes listed in the following table were made on the same branch as this report. The app wasn't compiled when they were made, because `disc_golf_android/app/build.gradle.kts` on `main` has lost its Kotlin plugin and dependencies, so CI doesn't compile the app's Kotlin sources. The changed files pass a Kotlin syntax check, but the fixes still need a compile and a device check once a separate fix restores the build.

| Finding | What changed |
|---|---|
| [P1] Outline contrast | `outline` is `#6B7A99` (3.69:1 on `surface`). The earlier value moves to `outlineVariant`, which dividers use. |
| [P1] Purple and score contrast | `AppColors.Roulette` is `#CE93D8` (6.65:1 on `surface`) and `AppColors.Bad` is `#FF8A80` (6.96:1). The wheel keeps its deeper purples, which never carry text. Hole-tile stroke counts use `OnSurface`, and the score color stays on the tile's border and tint. |
| [P1] Keyboard insets | `MainActivity` applies `imePadding()` once at the root, and `ResearchSearchScreen` no longer applies its own. |
| [P1] Landscape video screens | A shared `VideoWithControls` layout in `Common.kt` puts the controls in a scrolling side column when the window is wider than it is tall and under 480dp tall. The flight player, pose correction, and trim screens use it. |
| [P2] Canvases without TalkBack | `AngleWaveform` describes its range and current value and offers "Go to the start" and "Go to *phase*" actions. The form history trend chart has a description. The marking and pose canvases say what they're for and point to the frame step buttons. |
| [P2] Color roles | 109 of the 140 neutral-color reads (`Muted`, `OnSurface`, `Surface`, `Background`, `TopBar`, `Accent`) now go through `MaterialTheme.colorScheme`. The other 31 are in draw scopes, `Modifier.background` and `border` calls, or plain functions, where a composable read isn't allowed. Feature accents and status colors stay as `AppColors` tokens. |
| [P2] Predictive Back | The manifest sets `android:enableOnBackInvokedCallback="true"`. |
| [P2] History badge at large font sizes | The score ring is a square of at least 56dp that grows with its content. |
| [P2] Tablet layout | On windows 840dp and wider, a knowledge base category shows its questions and the selected answer side by side. |
| [P2] List keys | The phase comparison, phase selector, and knowledge base grids use stable keys. The roulette history, par grid, and hole-tile grid keep index keys. The par and hole grids are positional, and stored history entries have no guaranteed-unique field, so a duplicate key would crash the list. |
| [P3] Reduce motion | `rememberReduceMotion()` watches the system setting, so it updates while the screen is open. |
| [P3] Home icon tile | `NavigationCard` draws the feature icon on its own, without the tinted tile. |
| [P3] Product context | `PRODUCT.md` at the repository root records the product context. It was drafted from the repository, and its inferred facts are marked for the owner to confirm. |
