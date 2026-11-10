"""Command line for the flight tracking benchmark.

    python -m flightbench import-coco <export dir> --out labels/x.json
    python -m flightbench map-frames labels/x.json <export dir> <video dir>
    python -m flightbench leakage labels/x.json
    python -m flightbench score --truth labels/x.json --pred out.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import metrics
from .formats import parse_predictions, parse_truth
from .roboflow import import_coco_export, roboflow_leakage, select_split


def _percent(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.1%}"


def _import_coco(args: argparse.Namespace) -> int:
    sizes = json.loads(Path(args.sizes).read_text(encoding="utf-8")) if args.sizes else None
    truth_set = import_coco_export(args.export_dir, sizes, args.class_name)
    for key, value in (("source", args.source), ("license", args.license)):
        if value:
            truth_set = {key: value, **truth_set}
    Path(args.out).write_text(json.dumps(truth_set, indent=1) + "\n", encoding="utf-8")
    frames = sum(len(c["frames"]) for c in truth_set["clips"].values())
    print(f"wrote {len(truth_set['clips'])} clips and {frames} frames to {args.out}")
    return 0


def _map_frames(args: argparse.Namespace) -> int:
    from .videoframes import apply_video_frames, match_export_to_videos

    path = Path(args.truth)
    truth_set = json.loads(path.read_text(encoding="utf-8"))
    matches = match_export_to_videos(args.export_dir, args.video_dir)
    apply_video_frames(truth_set, matches)
    path.write_text(json.dumps(truth_set, indent=1) + "\n", encoding="utf-8")
    for clip, body in truth_set["clips"].items():
        print(f"  {body['frame_numbering']:5}  {clip}")
    return 0


def _leakage(args: argparse.Namespace) -> int:
    truth_set = json.loads(Path(args.truth).read_text(encoding="utf-8"))
    leaks = roboflow_leakage(truth_set)
    print(f"{len(leaks)} of {len(truth_set['clips'])} clips have frames in more than one Roboflow split")
    for clip, splits in leaks.items():
        print(f"  {clip}: {', '.join(splits)}")
    print("clip-level split:")
    for clip, body in truth_set["clips"].items():
        print(f"  {body.get('bench_split', '?'):5}  {len(body['frames']):4} frames  {clip}")
    return 0


def _score(args: argparse.Namespace) -> int:
    truth_set = json.loads(Path(args.truth).read_text(encoding="utf-8"))
    if args.split:
        truth_set = select_split(truth_set, args.split)
    if not truth_set["clips"]:
        print("no clips to score", file=sys.stderr)
        return 2
    truth = parse_truth(truth_set)
    predictions = parse_predictions(json.loads(Path(args.pred).read_text(encoding="utf-8")))
    summary, scores = metrics.score(truth, predictions, args.tolerance)
    if args.json:
        print(json.dumps({"summary": summary.to_dict(), "clips": [vars(s) for s in scores]}, indent=1))
    else:
        print(f"method: {summary.method}   clips: {summary.clips}   visible frames: {summary.visible_frames}")
        print(f"located {_percent(summary.located_rate)}   coverage {_percent(summary.coverage_rate)}   "
              f"precision {_percent(summary.precision)}   false-trail clips {_percent(summary.false_trail_clip_rate)}")
        print(f"worst clip located {_percent(summary.worst_clip_located_rate)}   "
              f"slowest clip {'n/a' if summary.max_seconds is None else f'{summary.max_seconds:.1f} s'}")
        for s in scores:
            print(f"  {s.located:4}/{s.visible_frames:<4} located  {s.wrong:3} wrong  "
                  f"{s.false_points:3} false  {s.clip}")
    missed = metrics.failures(summary)
    for line in missed:
        print(f"MISSED: {line}")
    return 1 if missed and args.enforce else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="flightbench", description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)

    coco = commands.add_parser("import-coco", help="build a truth set from a Roboflow COCO export")
    coco.add_argument("export_dir")
    coco.add_argument("--out", required=True)
    coco.add_argument("--sizes", help="JSON map of original file name to [width, height]")
    coco.add_argument("--class-name", default="disc")
    coco.add_argument("--source")
    coco.add_argument("--license")
    coco.set_defaults(run=_import_coco)

    frames = commands.add_parser(
        "map-frames", help="renumber labels by video frame (needs ffmpeg and numpy)"
    )
    frames.add_argument("truth")
    frames.add_argument("export_dir")
    frames.add_argument("video_dir")
    frames.set_defaults(run=_map_frames)

    leak = commands.add_parser("leakage", help="list clips split across Roboflow splits")
    leak.add_argument("truth")
    leak.set_defaults(run=_leakage)

    score = commands.add_parser("score", help="score predictions against a truth set")
    score.add_argument("--truth", required=True)
    score.add_argument("--pred", required=True)
    score.add_argument("--split", choices=["train", "valid", "test"], help="score only this clip-level split")
    score.add_argument("--tolerance", type=float, default=metrics.DEFAULT_TOLERANCE)
    score.add_argument("--json", action="store_true")
    score.add_argument("--enforce", action="store_true", help="exit 1 when a target is missed")
    score.set_defaults(run=_score)

    args = parser.parse_args(argv)
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())
