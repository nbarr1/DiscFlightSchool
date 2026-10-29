# Product

<!-- impeccable:product-schema 1 -->

> This record was drafted from the repository, not from an interview. Every fact marked _(inferred)_ is a hypothesis that the product owner should confirm or correct. Re-run `/impeccable init` to replace inferences with confirmed answers.

## Platform

android

## Users

- Disc golfers who want to improve their throws by reviewing video of their own flight paths and form. _(inferred)_
- Groups who play casual rounds and use Disc Roulette for random shot challenges and scoring. _(inferred)_

## Product Purpose

Disc Flight School turns a phone video of a throw into something a player can learn from. It tracks the disc's flight path, analyzes throwing posture against pro reference data, and backs its suggestions with a research-based knowledge base. Success means a player understands what to change in their throw. _(inferred from the README and the home screen copy)_

## Positioning

The app analyzes on the device: disc tracking uses an on-device YOLO detector with an optional server fallback, and pose analysis uses ML Kit. Form feedback compares the player's joint angles at each throw phase with a pro baseline database, and knowledge base answers cite the studies behind them. _(inferred)_

## Operating Context

- People record throws outdoors on a course or in a field, often in bright light, and review them on the spot or later. _(inferred)_
- Flight paths and pose skeletons are drawn as bright strokes over video, which is why the app's chrome is dark at every system setting (stated in `ui/theme/Theme.kt`).
- Training data upload to the project's server is opt-in and configured in Training settings.

## Capabilities and Constraints

- Four features: Flight Tracker, Form Coach, Disc Roulette, and Knowledge Base, plus a flight path gallery and Training settings.
- Native Android app in Kotlin and Jetpack Compose with Material 3. `minSdk` is 24.
- The app uses a single dark theme on purpose. Light mode and Dynamic Color are out of scope unless this decision changes.
- The in-app privacy policy (`PrivacyPolicy.kt`) must match `docs/privacy-policy.md`, and a test enforces this.
- Date and time formats are pinned by `FormattingTest`.
- The release target is Google Play.

## Brand Commitments

- The product name is "Disc Flight School."
- The app's mark is the basket drawable (`ic_disc_golf_basket`).
- Copy uses sentence case and plain language (from the earlier design pass in `docs/design-audit.md`).

## Evidence on Hand

- `disc_golf_android/app/src/main/assets/data/pro_baseline_db.json` holds the pro reference angles.
- `disc_golf_android/app/src/main/assets/data/knowledge_base.json` holds the knowledge base articles and study citations.
- No testimonials, user research, or usage data exist in the repository. Future work must not invent them.

## Accessibility & Inclusion

- Text meets WCAG 2.2 AA contrast, and input boundaries meet 3:1, because people use the app outdoors (`docs/impeccable-audit.md`).
- Text uses the Material type scale in `sp`, so the system font size applies.
- Hand-driven animations honor the system Remove animations setting.
