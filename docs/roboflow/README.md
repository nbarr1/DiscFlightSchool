# Roboflow Workflow definitions

These files are the Workflow definitions that the removed flight tracker
mirrored, read from the `disc-golf-tracer` Roboflow workspace on
November 10, 2026. The file name is the Workflow's URL slug.

| File | What it is |
|---|---|
| `disc-golf-flight-tracker-1789645514948.json` | The video Workflow: detect, keep the `disc` class, track with OC-SORT, and draw the trail. |
| `disc-golf-flight-tracker.json` | The inner Workflow that the other two call. It runs the object detection model, and its `model_id` default selects the dataset version 2 model. |
| `disc-golf-flight-tracker-vdisc-golf-flight-tracker-2-rfdetr-small-t1-logic.json` | The single-image Workflow. |

The files are a record, not a deployment. Editing one doesn't change the
Workflow on Roboflow. `docs/flight-tracking-rebuild-reference.md` explains the
pipeline these definitions describe.
