import json
import tempfile
import unittest
from pathlib import Path

from flightbench import metrics
from flightbench.__main__ import main
from flightbench.clips import leaking_clips, parse_frame_name, split_by_clip
from flightbench.formats import parse_predictions, parse_truth
from flightbench.roboflow import import_coco_export, roboflow_leakage, select_split


def truth(frames, width=1000, height=1000, clip="a"):
    return parse_truth({"clips": {clip: {"width": width, "height": height, "frames": frames}}})


def predictions(frames, clip="a", seconds=None):
    body = {"frames": frames}
    if seconds is not None:
        body["seconds"] = seconds
    return parse_predictions({"method": "m", "clips": {clip: body}})


class ClipNames(unittest.TestCase):
    def test_parses_clip_and_frame(self):
        self.assertEqual(parse_frame_name("Snapchat-1_frame_012.jpg"), ("Snapchat-1", 12))

    def test_keeps_an_earlier_frame_marker_in_the_clip_id(self):
        self.assertEqual(parse_frame_name("a_frame_1_frame_02.png"), ("a_frame_1", 2))

    def test_rejects_other_names(self):
        with self.assertRaises(ValueError):
            parse_frame_name("holiday.jpg")


class ClipSplit(unittest.TestCase):
    counts = {"big": 60, "b": 12, "c": 10, "d": 8, "e": 6, "f": 4}

    def test_every_clip_gets_exactly_one_split(self):
        assignment = split_by_clip(self.counts)
        self.assertEqual(set(assignment), set(self.counts))
        self.assertLessEqual(set(assignment.values()), {"train", "valid", "test"})

    def test_largest_clip_trains_and_each_split_is_used(self):
        assignment = split_by_clip(self.counts)
        self.assertEqual(assignment["big"], "train")
        self.assertEqual(set(assignment.values()), {"train", "valid", "test"})

    def test_is_independent_of_input_order(self):
        reordered = dict(reversed(list(self.counts.items())))
        self.assertEqual(split_by_clip(self.counts), split_by_clip(reordered))

    def test_rejects_fractions_that_leave_no_training_data(self):
        with self.assertRaises(ValueError):
            split_by_clip(self.counts, valid=0.5, test=0.5)

    def test_reports_only_clips_in_several_splits(self):
        leaks = leaking_clips({"a": {"train", "test"}, "b": {"train"}})
        self.assertEqual(leaks, {"a": ["test", "train"]})


class Formats(unittest.TestCase):
    def test_visible_frame_needs_a_position(self):
        with self.assertRaises(ValueError):
            truth([{"frame": 1, "visible": True}])

    def test_duplicate_frames_are_refused(self):
        with self.assertRaises(ValueError):
            truth([{"frame": 1, "visible": False}, {"frame": 1, "visible": False}])
        with self.assertRaises(ValueError):
            predictions([{"frame": 1, "x": 0, "y": 0}, {"frame": 1, "x": 0, "y": 0}])


class Scoring(unittest.TestCase):
    def test_counts_located_wrong_missed_and_false_points(self):
        clips = truth(
            [
                {"frame": 1, "visible": True, "x": 0.5, "y": 0.5},
                {"frame": 2, "visible": True, "x": 0.5, "y": 0.5},
                {"frame": 3, "visible": True, "x": 0.5, "y": 0.5},
                {"frame": 4, "visible": False},
            ]
        )
        predicted = predictions(
            [
                {"frame": 1, "x": 0.51, "y": 0.5},  # 10 px of a 1414 px diagonal
                {"frame": 2, "x": 0.9, "y": 0.5},
                {"frame": 4, "x": 0.1, "y": 0.1},
                {"frame": 99, "x": 0.1, "y": 0.1},  # unlabeled, so not scored
            ]
        )
        summary, (clip,) = metrics.score(clips, predicted)
        self.assertEqual((clip.located, clip.wrong, clip.false_points), (1, 1, 1))
        self.assertEqual(clip.covered, 2)
        self.assertAlmostEqual(summary.located_rate, 1 / 3)
        self.assertAlmostEqual(summary.coverage_rate, 2 / 3)
        self.assertAlmostEqual(summary.precision, 1 / 3)

    def test_tolerance_is_measured_in_pixels_of_the_real_frame(self):
        frames = [{"frame": 1, "visible": True, "x": 0.5, "y": 0.5}]
        off_by_x = predictions([{"frame": 1, "x": 0.53, "y": 0.5}])
        # 0.03 of the width is 57.6 px wide of a 2203 px diagonal: outside 2%.
        _, (wide,) = metrics.score(truth(frames, 1920, 1080), off_by_x)
        # The same offset on a portrait frame is 32.4 px: inside 2%.
        _, (tall,) = metrics.score(truth(frames, 1080, 1920), off_by_x)
        self.assertEqual((wide.located, tall.located), (0, 1))

    def test_a_skipped_clip_scores_as_all_misses(self):
        clips = truth([{"frame": 1, "visible": True, "x": 0.5, "y": 0.5}])
        summary, _ = metrics.score(clips, parse_predictions({"method": "m", "clips": {}}))
        self.assertEqual(summary.located_rate, 0)

    def test_predictions_for_an_unknown_clip_are_refused(self):
        clips = truth([{"frame": 1, "visible": False}])
        with self.assertRaises(ValueError):
            metrics.score(clips, predictions([], clip="other"))

    def test_false_trail_needs_several_mostly_wrong_points(self):
        frames = [{"frame": n, "visible": False} for n in range(4)]
        drawn = [{"frame": n, "x": 0.5, "y": 0.5} for n in range(3)]
        _, (trail,) = metrics.score(truth(frames), predictions(drawn))
        _, (blip,) = metrics.score(truth(frames), predictions(drawn[:2]))
        self.assertTrue(trail.is_false_trail)
        self.assertFalse(blip.is_false_trail)

    def test_targets(self):
        frames = [{"frame": n, "visible": True, "x": 0.5, "y": 0.5} for n in range(10)]
        hits = [{"frame": n, "x": 0.5, "y": 0.5} for n in range(9)]
        good, _ = metrics.score(truth(frames), predictions(hits, seconds=12))
        self.assertEqual(metrics.failures(good), [])
        slow, _ = metrics.score(truth(frames), predictions(hits, seconds=31))
        self.assertEqual(len(metrics.failures(slow)), 1)
        untimed, _ = metrics.score(truth(frames), predictions(hits[:8]))
        self.assertEqual(len(metrics.failures(untimed)), 2)


def write_export(root: Path) -> None:
    def coco(names_and_boxes):
        images, annotations = [], []
        for index, (name, box) in enumerate(names_and_boxes):
            images.append(
                {"id": index, "file_name": name + ".rf.x.jpg", "width": 512, "height": 512,
                 "extra": {"name": name}}
            )
            if box:
                annotations.append({"id": index, "image_id": index, "category_id": 1, "bbox": box})
        return {
            "categories": [{"id": 0, "name": "group"}, {"id": 1, "name": "disc"}],
            "images": images,
            "annotations": annotations,
        }

    splits = {
        "train": [("one_frame_02.jpg", [100, 200, 24, 12]), ("two_frame_1.jpg", None)],
        "test": [("one_frame_01.jpg", [0, 0, 512, 512])],
    }
    for split, content in splits.items():
        (root / split).mkdir()
        (root / split / "_annotations.coco.json").write_text(json.dumps(coco(content)))


class RoboflowImport(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.root = Path(self.dir.name)
        write_export(self.root)

    def test_groups_frames_by_clip_and_normalizes_box_centers(self):
        sizes = {"one_frame_01.jpg": [1080, 1920], "one_frame_02.jpg": [1080, 1920]}
        truth_set = import_coco_export(self.root, sizes)
        one = truth_set["clips"]["one"]
        self.assertEqual((one["width"], one["height"]), (1080, 1920))
        self.assertEqual([f["frame"] for f in one["frames"]], [1, 2])
        second = one["frames"][1]
        self.assertAlmostEqual(second["x"], 112 / 512, places=4)
        self.assertAlmostEqual(second["y"], 206 / 512, places=4)
        self.assertEqual(truth_set["clips"]["two"]["frames"], [
            {"frame": 1, "visible": False, "roboflow_split": "train"}
        ])
        parse_truth(truth_set)

    def test_reports_leakage_and_selects_a_clip_level_split(self):
        truth_set = import_coco_export(self.root)
        self.assertEqual(roboflow_leakage(truth_set), {"one": ["test", "train"]})
        chosen = {split: set(select_split(truth_set, split)["clips"]) for split in ("train", "valid", "test")}
        self.assertEqual(set().union(*chosen.values()), {"one", "two"})

    def test_command_line_round_trip(self):
        out = self.root / "truth.json"
        self.assertEqual(main(["import-coco", str(self.root), "--out", str(out)]), 0)
        pred = self.root / "pred.json"
        pred.write_text(json.dumps({"method": "none", "clips": {}}))
        self.assertEqual(main(["score", "--truth", str(out), "--pred", str(pred)]), 0)
        self.assertEqual(main(["score", "--truth", str(out), "--pred", str(pred), "--enforce"]), 1)


class VideoFrames(unittest.TestCase):
    def test_renumbers_matched_clips_and_marks_the_rest(self):
        from flightbench.videoframes import apply_video_frames

        truth_set = {"clips": {
            "one": {"width": 10, "height": 10, "frames": [
                {"frame": 2, "visible": False}, {"frame": 1, "visible": False}]},
            "two": {"width": 10, "height": 10, "frames": [{"frame": 1, "visible": False}]},
        }}
        video = {"file": "one.mp4", "frames": 40, "fps": 30.0}
        matches = {"one": {"video": video, "frames": {"1": 0, "2": 9}}}
        apply_video_frames(truth_set, matches)
        one = truth_set["clips"]["one"]
        self.assertEqual([(f["frame"], f["label_frame"]) for f in one["frames"]], [(0, 1), (9, 2)])
        self.assertEqual((one["frame_numbering"], one["video"]), ("video", video))
        self.assertEqual(truth_set["clips"]["two"]["frame_numbering"], "label")
        # A second pass must not renumber again.
        apply_video_frames(truth_set, matches)
        self.assertEqual([f["frame"] for f in one["frames"]], [0, 9])


class CommittedLabels(unittest.TestCase):
    def test_committed_truth_sets_parse_and_keep_clips_whole(self):
        labels = sorted((Path(__file__).parent.parent / "labels").glob("*.json"))
        self.assertTrue(labels)
        for path in labels:
            truth_set = json.loads(path.read_text(encoding="utf-8"))
            parse_truth(truth_set)
            for clip, body in truth_set["clips"].items():
                self.assertIn(body["bench_split"], ("train", "valid", "test"), clip)


if __name__ == "__main__":
    unittest.main()
