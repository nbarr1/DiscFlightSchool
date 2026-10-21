# Design audit and polish pass

This document records an Impeccable audit and polish pass over the Disc Flight School Android app. It covers every screen in `disc_golf_android/app`, what was found, and what was changed.

## Scope

The repository contains one client app: the Android app (Kotlin, Jetpack Compose, Material 3). There is no iOS app and no web app in the repository, so neither was audited or changed. The `server/` tracking service has no user interface.

## Rollback point

The branch `pre-impeccable` points at `main` as it stood before this pass (commit `1ee3101`). To roll back after merging, revert the merge commit, or reset to `pre-impeccable`.

## Health scores

The following table scores each audit dimension from 0 to 4, before and after the pass.

| Dimension | Before | After | Notes |
|---|---|---|---|
| Accessibility | 2 | 3 | Labels, roles, and headings added. Some custom canvases still expose no semantics. |
| Navigation and system Back | 2 | 4 | Every sheet, dialog, and full-screen player now closes on Back. |
| Visual hierarchy | 2 | 3 | One filled primary action per screen. Per-feature colors kept as accents only. |
| Responsive and tablet | 1 | 3 | Content columns capped at a readable width. Grids adapt to width. |
| Feedback and error states | 2 | 3 | Undo for Clear, honest upload results, and empty states. |
| Performance | 2 | 3 | Gallery thumbnails decode off the main thread at reduced size. |
| Motion | 2 | 3 | Spin animations respect the system Remove animations setting. |

## Findings and fixes

### P0: blocks a task or traps the user

- **Flight player sheets trapped Back.** The mode and camera choice sheets couldn't be dismissed. Dismissing the mode sheet now leaves the screen, and dismissing the camera sheet returns to the mode sheet.
- **Detection dialog couldn't be cancelled with Back.** Back now cancels detection, the same as the Cancel button. Tapping outside no longer dismisses it by accident.
- **Cloud trace kept running after leaving.** Back during a cloud trace now cancels it.
- **Gallery player ignored Back.** Back now closes the player before leaving the gallery.
- **Pose corrections were lost silently.** Leaving with unsaved corrections now asks first, and Back exits step-by-step mode before leaving.

### P1: wrong or misleading

- **Clear removed all marked points with no undo.** A snackbar now offers Undo and restores the points, anchors, and result.
- **The flight trim screen said "Next, mark the throw phases."** It now says "Next, choose how to find the disc" and uses a tracking icon.
- **A zero-length trim was accepted.** Trims shorter than half a second disable the confirm button and explain why.
- **Suggestions stayed on "Analyzing..." when there were none.** They now say "Working out your cues..." while loading, then explain when no cues apply.
- **Phase comparison showed 0% with nothing to compare.** It now shows an empty state.
- **Upload results overstated success.** Partial uploads and failures now say exactly what happened.
- **Status bar icons turned dark in light system mode,** which hid them against the dark app background. They now stay light.
- **A cancelled video picker showed "No video selected."** Cancelling now returns without a message.
- **The phase picker's Analyze action hid in the top bar.** It is now a bottom button that counts the phases still to mark.

### P2: hierarchy, consistency, and reach

- **Color soup in action rows.** Flight player, flight tracker, form coach, roulette, and round screens each had several brightly colored filled buttons. Each screen now has one filled primary, tonal secondaries, and outlined tertiaries. Clear uses an outlined button in the error color.
- **No visible way to spin.** The roulette wheels only responded to taps on the wheel. Both now have a Spin button, the wheel has a role and label, and the result scrolls into view.
- **Hole tiles were smaller than 48dp.** The scorecard grid adapts to width with 48dp minimum tiles, and each tile announces what it opens.
- **Finish round was easy to miss.** A full-width Finish round button appears when every hole is scored.
- **Tablet stretching.** Content on every list and form screen is capped at a 640dp readable column.
- **Clipped cards at large font sizes.** Knowledge base cards use a minimum height instead of a fixed aspect ratio. Onboarding pages scroll when the text doesn't fit.
- **Home cards duplicated a private component.** A shared `NavigationCard` replaces the per-screen cards on home and flight tracker.

### P3: polish

- Onboarding shows the app's basket mark instead of a baseball icon, uses one background for every page, keeps the button row steady on the last page, and announces "Page X of N".
- Copy follows sentence case: "No comparison" replaces "— None —", "Answer" replaces "FAQ detail", and counts are pluralized.
- `timeAgo` says "1 day ago" instead of "1 days ago".
- Long top bar titles end with an ellipsis instead of wrapping.

## Positive findings

- Edge-to-edge layout and inset handling were already in place.
- Every screen already used the shared `AppTopBar` and theme colors.
- The form coach already worked on a copy of the analysis, so discarding corrections never touched saved data.
- Error messages were already specific and written in plain language.

## Not changed

- `PrivacyPolicy.kt` stays in sync with `docs/privacy-policy.md`, and tests compare them.
- Date and time formats are pinned by `FormattingTest`.
- The "Training settings" title is referenced by the privacy policy, tests, and README.

## Verification

The Android SDK couldn't be downloaded in the environment that made these changes, so the app wasn't built locally. The Android Tests workflow on the pull request is the compile and unit-test check.

## Follow-up

There is no `PRODUCT.md` describing the product's users and tone. Running `/impeccable init` creates one, which future design passes read before making changes.
