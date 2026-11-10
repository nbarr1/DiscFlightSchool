# Flight tracking rebuild plan

Flight tracking was removed in commit `01c1437` to be rebuilt.
`docs/flight-tracking-rebuild-reference.md` records what the removed code did.
This page is the plan for the rebuild and tracks its progress.

## Why the plan starts with measurement

The removed tracker was never measured. It was never run on a phone, and the
history holds no accuracy or timing figure for it. So this plan doesn't name a
winning method up front. It compares a short list of methods on the same
footage and builds the app around the one that meets the targets.

## Requirements

- **Output:** a trail on the video, plus a 2D reading of the flight's shape
  with no real-world units.
- **Footage:** handheld, and the camera may pan.
- **Processing:** on the device by default. A server is an optional later
  path.

## Approach

The pipeline has three stages, and measurement picks the detector:

1. **Stabilize.** Estimate camera motion between frames, so a panning camera
   doesn't look like a moving disc. This replaces the removed step where the
   user tapped two background points.
2. **Find candidates.** Produce scored disc candidates for each frame.
3. **Solve and correct.** Fit one trajectory through the whole clip, flag weak
   spans, and let the player fix a point and solve again. Manual keyframe
   tracking stays as the fallback.

Tracking runs after recording, on a trimmed clip with one disc. That allows
solving over the whole clip with past and future frames, instead of an online
tracker such as OC-SORT. This choice is a judgment that phase 1 tests.

## Phases

### Phase 0: benchmark kit and data

Status: in progress.

Done:

- The three Workflow definitions are in `docs/roboflow/`.
- `tools/flight-bench/` holds the label format, the metrics, and a split that
  keeps each clip whole.
- `tools/flight-bench/labels/roboflow-v3.json` holds the Roboflow labels
  grouped by clip.

- Each label in the nine clips with a video file is matched to its video
  frame. The three YouTube clips have no video file.

Still to do:

- Label consecutive frames on the held-out clips. Eight of the nine clips
  with video have a label only every 7-16 frames. The 878 unlabeled flight
  frames of the five held-out clips are uploaded to the Roboflow project as
  `<clip>_vframe_<video frame>.jpg`, with the tag `dense-heldout`. The
  version 3 model pre-labeled them, and the labels need a person's review
  before they count as ground truth.
- Score the removed pipeline as the baseline, and adjust the targets.

Findings so far:

- Roboflow's split puts frames of all 12 clips in train, valid, and test. The
  models' reported figures (mAP50 of about 75, recall of 71-75%) are measured
  on frames next to training frames, so they overstate accuracy on a new
  throw.
- No model on Roboflow was trained on the clip-level `train` split alone, so
  none can be scored fairly on the clip-level `test` split yet.
- One clip is labeled on nearly every frame. The rest are labeled two to four
  times per second, which can't train a multi-frame method.

### Phase 1: compare candidates offline

Run each candidate on the same held-out clips, and record the result and the
choice in `docs/flight-tracking-decision.md`.

| Candidate | Training needed | Reason to include |
|---|---|---|
| A. Removed pipeline: RF-DETR Small on the full frame, then OC-SORT | Retrain on the clip-level `train` split | Baseline |
| B. Nano detector on crops that follow the predicted path | Fine-tune on the labels | Small enough to bundle, and keeps the disc at full resolution |
| C. Frame differencing on stabilized frames | None | No model and the lowest cost |
| D. Multi-frame heatmap network (TrackNet or WASB family) | Train on consecutive labeled frames | Designed for small, fast objects |

Every candidate feeds the same whole-clip solver, so the comparison isolates
the quality of the candidates. The solver is also compared with OC-SORT on
candidate A's detections.

### Phase 2: pure-Kotlin pipeline in `:core`

Restore the types, trajectory cleanup, spline tracker, and `WorldAnchor`
transform math from `6b54b28` with their tests. Add camera-motion estimation,
the whole-clip solver, and the flight-shape reading (time in the air, apex,
sideways deviation each way, and a shape label, all relative to the screen).
Check the Kotlin output against fixtures exported from `tools/flight-bench/`.

### Phase 3: Android runtime in `:app`

Add a sequential `MediaCodec` decoder, choose the inference runtime from
measured milliseconds per frame on real phones, and bundle the model when it
is under about 10 MB.

### Phase 4: screens

Restore the routes, the Home card, the overlay, export, and the gallery.
Rebuild the player as several smaller files, and add the flight-shape card
and tap-to-correct.

### Phase 5: optional server path

Build this phase only if on-device results miss the targets on hard clips. It
needs a proxy for the API key and matching edits to `docs/privacy-policy.md`
and `PrivacyPolicy.kt`.

## Targets

These are proposals until the baseline run exists:

- At least 85% of frames with a visible disc are located within 2% of the
  frame diagonal.
- At most 5% of clips get a trail that is mostly not the disc.
- A five-second clip takes at most 30 seconds on a mid-range phone.
