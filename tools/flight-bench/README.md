# Flight tracking benchmark

This tool scores a disc tracker's output against labeled frames. It exists so
that every tracking method considered for the rebuild is measured the same
way, on throws the method has not trained on. `docs/flight-tracking-plan.md`
describes where it fits.

It needs Python 3.10 or later and nothing else.

## What is here

| Path | Contents |
|---|---|
| `flightbench/` | The label and prediction formats, the clip-level split, the metrics, and the command line. |
| `labels/roboflow-v3.json` | The labels from version 3 of the Roboflow dataset, grouped by clip. |
| `tests/` | Unit tests. |
| `data/` | Videos and frames you download. Git ignores this folder. |

## Run it

Run the commands from this folder.

To run the tests:

```bash
python3 -m unittest discover -s tests
```

To score a method's predictions on the held-out clips:

```bash
python3 -m flightbench score --truth labels/roboflow-v3.json --pred predictions.json --split test
```

Add `--enforce` to exit with status 1 when a target is missed, and `--json`
for machine-readable output.

To list which clips Roboflow's own split spreads across train, valid, and
test:

```bash
python3 -m flightbench leakage labels/roboflow-v3.json
```

To rebuild the label file from a fresh Roboflow COCO export:

```bash
python3 -m flightbench import-coco data/export --sizes data/sizes.json --out labels/roboflow-v3.json
```

To renumber the labels by video frame, put each clip's video in `data/videos/`
as `<clip>.mp4` and run the following command. It needs `ffmpeg` and `numpy`.

```bash
python3 -m flightbench map-frames labels/roboflow-v3.json data/export data/videos
```

`--sizes` is a JSON map of each original file name to `[width, height]`. The
export is resized to 512x512, and the tolerance is measured in pixels of the
original frame, so the original size has to come from somewhere else.

## Formats

Positions are the disc center, normalized to 0-1 of the frame, with the
origin at the top left. `flightbench/formats.py` documents both files.

A prediction file looks like this:

```json
{"method": "frame-differencing", "clips": {
  "Snapchat-1788214628": {
    "seconds": 4.2,
    "frames": [{"frame": 5, "x": 0.41, "y": 0.52}]}}}
```

A clip's `frame_numbering` says what its frame numbers count:

`video`
: The 0-based index of the frame in the clip's video, in decode order. The
  number from the label's file name is kept as `label_frame`. The nine clips
  with a video file use this numbering.

`label`
: The number from the label's file name (`<clip>_frame_<number>.jpg`), which
  counts extracted frames. The three YouTube clips use this numbering, because
  their video files aren't available.

A method that reads video must report video frame indexes.

## Metrics

Only labeled frames are scored.

Located rate
: The share of frames with a visible disc where the prediction is within 2%
  of the frame diagonal of the label.

Coverage rate
: The share of frames with a visible disc where the method predicted
  anything.

Precision
: The share of predictions on labeled frames that are correct. A prediction
  on a frame labeled as empty is incorrect.

False-trail clips
: The share of clips where the method drew at least three scored points and
  fewer than half were correct.

Worst clip located rate
: The located rate of the clip the method did worst on.

The proposed targets are a located rate of at least 85%, at most 5%
false-trail clips, and at most 30 seconds for the slowest clip. They are
proposals until a baseline run exists.

## The clip-level split

Roboflow split the dataset by image. All 12 source clips have frames in
train, valid, and test, so a model is tested on frames that sit next to the
ones it trained on, and its reported accuracy is higher than it would be on a
new throw.

`labels/roboflow-v3.json` adds a `bench_split` to each clip that keeps every
clip whole: 293 frames in train, 62 in valid, and 68 in test. A model must be
trained only on the `train` clips for its `test` score to mean anything. None
of the three models on Roboflow meets that condition.

## Limits of the labels

- There are 12 clips, and two of them supply 237 of the 423 frames.
- Only one clip is labeled on nearly every frame (145 of its 184 frames), and
  the clip-level split puts it in `train`. The other eight clips with video
  have a label every 7-16 frames, about two to four per second. The labels
  can't train a method that needs consecutive frames, and they check a
  trajectory at only a few points.
- Three clips are YouTube Shorts and the rest came through messaging apps,
  which re-encode video. They may not look like a clip recorded in the app.
- The nine clips with video are filmed from behind the thrower at about 30
  frames per second. Eight are on wooded holes and one is in an open field.
- The disc's longer side has a median of 24 pixels in the original frames
  (9 at the tenth percentile). Frames where the disc was too small for the
  labeler to see are likely missing, so the dataset understates how small the
  disc gets.

The images are not in this repository. The dataset is public on Roboflow
under CC BY 4.0.
