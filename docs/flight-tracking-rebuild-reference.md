# Flight tracking rebuild reference

The app's flight tracking was removed so it can be rebuilt from scratch. This
page records the Roboflow Workflow that the removed code mirrored, so a new
implementation can follow the same processing pipeline. It describes what the
removed code did, not a design for the new one.

The removed code is still in git history. Its last commit on `main` is
`6b54b28fb06cade56efddc14f602234e0a4f83f5`. To browse it, run:

```bash
git show 6b54b28:disc_golf_android/core/src/main/kotlin/com/discflightschool/core/tracking/OcSortTracker.kt
git checkout 6b54b28 -- <path>   # restore one file into the working tree
```

## The Workflow definition files

The Workflow definitions are in `docs/roboflow/`, read from the Roboflow
workspace after the removal. The details on this page come from the removed
source and the README, and they match those definitions. The rebuild's plan
is in `docs/flight-tracking-plan.md`.

## Workflow identifiers

The removed code used these identifiers:

| Item | Value |
|---|---|
| Workspace | `disc-golf-tracer` |
| Video Workflow (hosted, used by the removed server) | `disc-golf-flight-tracker-1789645514948` |
| Inner Workflow name | `disc-golf-flight-tracker` |
| Image input name | `image` |
| Model (the inner Workflow's `model_id` default) | `disc-golf-tracer/disc-golf-flight-tracker-2-rfdetr-small-t1` |
| Model type | RF-DETR Small, 512x512 input, Apache 2.0 |
| Single-image Workflow | `disc-golf-flight-tracker-vdisc-golf-flight-tracker-2-rfdetr-small-t1-logic` |
| Video Workflow outputs | `output_image` (annotated frame), `tracked_disc` (OC-SORT output), `disc_detections` (raw model output) |
| Single-image Workflow output | `predictions` (image size and a list of boxes) |

## Processing pipeline

The on-device implementation ran these steps for each trimmed clip:

1. **Decode frames.** Frames were decoded at a fixed 30 fps from the trim start,
   at most 300 frames (10 seconds). The hosted Workflow runs at the clip's own
   frame rate instead. `MediaMetadataRetriever` was asked for
   `OPTION_CLOSEST`, so each frame matched its timestamp.
2. **Preprocess for RF-DETR.** The full-resolution frame was resized to the
   network size with Pillow's bilinear stretch resize (no letterboxing),
   divided by 255, and normalized per channel with the mean and standard
   deviation from the model package's `inference_config.json`, in NCHW
   layout. The loader refused any package whose config asked for a resize
   mode other than `stretch`, a color mode other than `rgb`, or any enabled
   preprocessing step other than `auto-orient`.
3. **Run the model.** The ONNX package's outputs are `dets` (`[queries, 4]`,
   center x, center y, width, and height as fractions of the input) and
   `labels` (`[queries, classes]` logits). Post-processing followed
   `inference-models`' `post_process_object_detection_results`: sigmoid
   scores, the top `queries` scores across every query and class, a strict
   threshold, box corners scaled to frame pixels and rounded half to even, and
   classes removed by the package's `class_name_removal` operations dropped.
4. **Filter.** Keep the `disc` class with confidence above 0.15, the
   `confidence` value the outer Workflow passes to its model step.
5. **Track with OC-SORT.** The Workflow's `roboflow_core/trackers_ocsort@v1`
   step runs Roboflow's `trackers` package 2.4.0. It's created with the
   video's frame rate and called once per frame, and detections with tracker
   id -1 are dropped. The disc Workflow uses these settings, which differ from
   the library defaults:

   | Setting | Value |
   |---|---|
   | `lost_track_buffer` | 30 |
   | `minimum_consecutive_frames` | 1 |
   | `minimum_iou_threshold` | 0.01 |
   | `direction_consistency_weight` | 0.4 |
   | `high_confidence_threshold` | 0.15 |
   | `delta_t` | 2 |

   The maximum frames without an update is `int(frame_rate / 30 *
   lost_track_buffer)`, truncated as Python's `int()` does.
6. **Pick each frame's disc.** Use the most confident tracked box. When the
   tracker kept none, use the most confident raw detection. Positions are
   normalized to the frame, with `x`/`y` at the box center.
7. **Clean up the path.** The removed app then mapped the 30 fps positions
   onto its own frame grid (nearest timestamp wins, higher confidence breaks a
   tie), dropped spatially incoherent points, smoothed with a three-frame
   window, and linearly filled gaps of up to 10 frames, marking filled points
   as interpolated. These steps were the app's own and aren't part of the
   Workflow.

## Model download

The model's weights are about 114 MB, over GitHub's file limit, so they were
never committed. The removed `scripts/fetch_disc_model.py` downloaded the
full-precision ONNX package (`onnx-model-package-v1`) from
`https://api.roboflow.com/models/v1/external/weights?modelId=<model id>`, the
weights API that self-hosted Inference uses, with the workspace's private key
in `ROBOFLOW_API_KEY` sent as `Authorization: Bearer`. It checked each file's
MD5 and wrote `weights.onnx`, `inference_config.json`, and `class_names.txt`
to `disc_golf_android/app/src/main/assets/models/rfdetr/`, which is still
git-ignored. CI ran it before every APK build from the `ROBOFLOW_API_KEY`
repository secret. That secret is no longer read by any workflow.

## Ports that were checked against Python fixtures

The removed tests compared the Kotlin ports with output from the Python
libraries, produced by the removed `scripts/generate_ocsort_fixture.py` and
`scripts/generate_pil_resize_fixture.py`. Recover those scripts and their
fixtures from the commit listed earlier to check a new port the same way.
