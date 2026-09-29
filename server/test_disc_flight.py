from __future__ import annotations

import base64
import inspect
import json
import logging
import os
import sys
import threading
import time
import types
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from training_server import Settings, create_app
from training_server.disc_flight import (
    Cancelled,
    DiscFlightJobManager,
    EmptyClip,
    NoAnnotatedFrames,
    RoboflowVideoProcessor,
    UnreadableVideo,
)
from training_server.storage import FileStorage


VIDEO = b"\x00\x00\x00\x18ftypmp42" + b"video-data"
AUTH = {"X-App-Key": "test-key"}


TRACK = {
    "fps": 30.0,
    "frameCount": 2,
    "detections": [{"frame": 1, "timeMs": 33, "x": 0.5, "y": 0.4, "width": 0.02, "height": 0.02, "confidence": 0.9}],
}


class FakeProcessor:
    clips: list = []

    def __init__(self, mode="success"):
        self.mode = mode
        self.closed = False

    def __call__(self, source, destination, cancel, update, clip=None):
        FakeProcessor.clips.append(clip)
        update(1, 2, "processing")
        if self.mode == "failure":
            raise ConnectionError("secret upstream detail")
        if self.mode == "no-frames":
            raise NoAnnotatedFrames("Roboflow processed no frames.")
        if self.mode == "empty-clip":
            raise EmptyClip("The selected part of the video has no frames. Choose a longer range.")
        if self.mode == "wait":
            while not cancel.wait(0.01):
                pass
            raise Cancelled()
        update(2, 2, "finalizing")
        destination.write_bytes(b"playable-mp4-placeholder")
        return {
            "framesWithDetections": 0 if self.mode == "no-detections" else 1,
            "detectionRate": 0.0 if self.mode == "no-detections" else 0.5,
            "frameErrors": 1 if self.mode == "frame-error" else 0,
            "track": TRACK,
        }

    def close(self):
        self.closed = True


def make_client(tmp_path: Path, mode="success", *, max_bytes=1024, client_api_key=None):
    settings = Settings(
        app_api_key="test-key",
        base_dir=tmp_path,
        roboflow_api_key="server-only",
        client_api_key=client_api_key,
        disc_flight_max_upload_bytes=max_bytes,
    )
    manager = DiscFlightJobManager(settings, lambda: FakeProcessor(mode))
    app = create_app(settings, FileStorage(settings), manager)
    return TestClient(app), manager


def start(
    client: TestClient,
    data=VIDEO,
    content_type="video/mp4",
    filename="throw.mp4",
    headers=AUTH,
    form=None,
):
    return client.post(
        "/api/disc-flight/jobs",
        headers=headers,
        files={"video": (filename, data, content_type)},
        data=form or {},
    )


def wait_for_terminal(client, job_id, token):
    headers = {**AUTH, "X-Job-Token": token}
    for _ in range(100):
        response = client.get(f"/api/disc-flight/jobs/{job_id}", headers=headers)
        if response.json()["status"] in {"complete", "failed", "cancelled"}:
            return response
        time.sleep(0.01)
    raise AssertionError("job did not finish")


def test_missing_video(tmp_path):
    client, _ = make_client(tmp_path)
    assert client.post("/api/disc-flight/jobs", headers=AUTH).status_code == 400


def test_unsupported_format(tmp_path):
    client, _ = make_client(tmp_path)
    response = start(client, content_type="text/plain", filename="throw.txt")
    assert response.status_code == 415


def test_oversized_upload_is_removed(tmp_path):
    client, _ = make_client(tmp_path, max_bytes=4)
    assert start(client).status_code == 413
    assert not list(tmp_path.glob("disc_flight_jobs/*"))


def test_missing_server_side_key(tmp_path):
    settings = Settings(app_api_key="test-key", base_dir=tmp_path)
    app = create_app(settings, FileStorage(settings), DiscFlightJobManager(settings))
    assert start(TestClient(app)).status_code == 503


def test_connection_failure_is_safe_and_cleans_input(tmp_path):
    client, manager = make_client(tmp_path, "failure")
    created = start(client).json()
    result = wait_for_terminal(client, created["jobId"], created["jobToken"])
    assert result.json()["status"] == "failed"
    assert "secret upstream detail" not in result.text
    assert not manager.jobs[created["jobId"]].input_path.exists()


def test_no_frames_failure_logs_its_reason(tmp_path, caplog):
    client, _ = make_client(tmp_path, "no-frames")
    with caplog.at_level(logging.ERROR, logger="disc_flight_school.disc_flight"):
        created = start(client).json()
        result = wait_for_terminal(client, created["jobId"], created["jobToken"]).json()
    assert result["status"] == "failed"
    [event] = [json.loads(record.getMessage()) for record in caplog.records]
    assert event["error"] == "NoAnnotatedFrames"
    assert event["detail"] == "Roboflow processed no frames."


def test_no_detections_and_per_frame_error_are_defensive(tmp_path):
    for mode, expected_errors in (("no-detections", 0), ("frame-error", 1)):
        client, _ = make_client(tmp_path / mode, mode)
        created = start(client).json()
        result = wait_for_terminal(client, created["jobId"], created["jobToken"]).json()
        assert result["status"] == "complete"
        assert result["summary"]["frameErrors"] == expected_errors
        if mode == "no-detections":
            assert result["summary"]["detectionRate"] == 0.0


def test_success_result_and_duplicate_prevention(tmp_path):
    client, _ = make_client(tmp_path, "wait")
    created = start(client).json()
    assert start(client).status_code == 409
    headers = {**AUTH, "X-Job-Token": created["jobToken"]}
    client.delete(f"/api/disc-flight/jobs/{created['jobId']}", headers=headers)

    success, _ = make_client(tmp_path / "success")
    created = start(success).json()
    status = wait_for_terminal(success, created["jobId"], created["jobToken"]).json()
    assert status["progress"] == 1.0
    response = success.get(
        status["resultVideoUrl"],
        headers={**AUTH, "X-Job-Token": created["jobToken"]},
    )
    assert response.status_code == 200
    assert response.headers["content-type"] == "video/mp4"


def test_cancel_and_cleanup(tmp_path):
    client, manager = make_client(tmp_path, "wait")
    created = start(client).json()
    headers = {**AUTH, "X-Job-Token": created["jobToken"]}
    response = client.delete(f"/api/disc-flight/jobs/{created['jobId']}", headers=headers)
    assert response.json()["status"] == "cancelled"
    wait_for_terminal(client, created["jobId"], created["jobToken"])
    job = manager.jobs[created["jobId"]]
    assert not job.input_path.exists()
    assert not job.output_path.exists()


def test_finished_jobs_expire_with_their_files(tmp_path):
    client, manager = make_client(tmp_path)
    manager.retention_seconds = 60
    created = start(client).json()
    wait_for_terminal(client, created["jobId"], created["jobToken"])
    job = manager.jobs[created["jobId"]]
    assert job.output_path.is_file()

    job.finished_at = time.monotonic() - 61
    headers = {**AUTH, "X-Job-Token": created["jobToken"]}
    response = client.get(f"/api/disc-flight/jobs/{created['jobId']}", headers=headers)

    assert response.status_code == 404
    assert created["jobId"] not in manager.jobs
    assert not job.directory.exists()


def test_a_running_job_never_expires(tmp_path):
    client, manager = make_client(tmp_path, "wait")
    manager.retention_seconds = 0
    created = start(client).json()
    headers = {**AUTH, "X-Job-Token": created["jobToken"]}

    assert client.get(f"/api/disc-flight/jobs/{created['jobId']}", headers=headers).status_code == 200
    client.delete(f"/api/disc-flight/jobs/{created['jobId']}", headers=headers)


def test_folders_left_by_an_earlier_process_are_swept(tmp_path):
    root = tmp_path / "disc_flight_jobs"
    stale = root / "stale-job"
    recent = root / "recent-job"
    stale.mkdir(parents=True)
    recent.mkdir()
    (stale / "result.mp4").write_bytes(b"old")
    old = time.time() - 2 * 24 * 60 * 60
    os.utime(stale, (old, old))

    DiscFlightJobManager(Settings(app_api_key="test-key", base_dir=tmp_path))

    assert not stale.exists()
    assert recent.exists()


CLIENT = {"X-App-Key": "shipped-in-the-app"}


def test_the_client_key_opens_the_detection_endpoints(tmp_path):
    client, _ = make_client(tmp_path, client_api_key="shipped-in-the-app")
    created = start(client, headers=CLIENT).json()
    headers = {**CLIENT, "X-Job-Token": created["jobToken"]}

    status = wait_for_terminal(client, created["jobId"], created["jobToken"]).json()
    assert status["status"] == "complete"
    assert client.get(status["trackUrl"], headers=headers).json() == TRACK
    assert client.get(status["resultVideoUrl"], headers=headers).status_code == 200


def test_the_client_key_cannot_reach_training_or_export(tmp_path):
    client, _ = make_client(tmp_path, client_api_key="shipped-in-the-app")
    # Anyone can extract the client key from the app, so it must not open the
    # dataset or start training runs.
    assert client.get("/api/training/export", headers=CLIENT).status_code == 403
    assert client.post("/api/training/start", headers=CLIENT).status_code == 403
    upload = client.post(
        "/api/training/upload",
        headers=CLIENT,
        data={"sample_id": "s1", "label": "0 0.5 0.5 0.1 0.1", "image_width": 4, "image_height": 4},
        files={"full_image": ("a.jpg", b"x", "image/jpeg"), "crop_image": ("b.jpg", b"x", "image/jpeg")},
    )
    assert upload.status_code == 403


def test_a_client_key_is_rejected_when_the_server_has_none(tmp_path):
    client, _ = make_client(tmp_path)
    assert start(client, headers=CLIENT).status_code == 403


def test_the_track_is_not_served_before_the_job_completes(tmp_path):
    client, _ = make_client(tmp_path, "wait")
    created = start(client).json()
    headers = {**AUTH, "X-Job-Token": created["jobToken"]}

    response = client.get(f"/api/disc-flight/jobs/{created['jobId']}/track", headers=headers)

    assert response.status_code == 409
    client.delete(f"/api/disc-flight/jobs/{created['jobId']}", headers=headers)


def test_a_clip_range_reaches_the_processor(tmp_path):
    FakeProcessor.clips = []
    client, _ = make_client(tmp_path)
    created = start(client, form={"start_ms": "1200", "end_ms": "4800"}).json()
    wait_for_terminal(client, created["jobId"], created["jobToken"])

    assert FakeProcessor.clips == [(1200, 4800)]


def test_two_ranges_of_one_video_are_not_duplicates(tmp_path):
    client, _ = make_client(tmp_path, "wait")
    first = start(client, form={"start_ms": "0", "end_ms": "2000"})
    second = start(client, form={"start_ms": "2000", "end_ms": "4000"})

    assert first.status_code == 202
    assert second.status_code == 202
    for created in (first.json(), second.json()):
        headers = {**AUTH, "X-Job-Token": created["jobToken"]}
        client.delete(f"/api/disc-flight/jobs/{created['jobId']}", headers=headers)


def test_a_range_past_the_end_says_so(tmp_path):
    client, _ = make_client(tmp_path, "empty-clip")
    created = start(client, form={"start_ms": "60000"}).json()

    status = wait_for_terminal(client, created["jobId"], created["jobToken"]).json()

    assert status["status"] == "failed"
    assert status["error"] == "The selected part of the video has no frames. Choose a longer range."


@pytest.mark.parametrize(
    "form",
    [{"start_ms": "-1"}, {"start_ms": "3000", "end_ms": "3000"}, {"end_ms": "0"}],
)
def test_an_invalid_clip_range_is_rejected(tmp_path, form):
    client, _ = make_client(tmp_path)
    assert start(client, form=form).status_code == 400


def test_another_job_token_cannot_read_or_cancel(tmp_path):
    client, _ = make_client(tmp_path, "wait")
    first = start(client).json()
    response = client.get(
        f"/api/disc-flight/jobs/{first['jobId']}",
        headers={**AUTH, "X-Job-Token": "someone-elses-token"},
    )
    assert response.status_code == 404
    response = client.delete(
        f"/api/disc-flight/jobs/{first['jobId']}",
        headers={**AUTH, "X-Job-Token": "someone-elses-token"},
    )
    assert response.status_code == 404
    client.delete(
        f"/api/disc-flight/jobs/{first['jobId']}",
        headers={**AUTH, "X-Job-Token": first["jobToken"]},
    )


def _image(label: str) -> dict:
    return {"type": "base64", "value": base64.b64encode(label.encode()).decode()}


class _SdkRoutedSession:
    """Delivers workflow outputs the way inference-sdk 1.7.1 does for a VideoFileSource.

    The server sends every name in data_output and stream_output over the data
    channel. The SDK then removes the stream_output names from what `on_data`
    receives and queues those images for `session.video()`, which `wait()`
    drains and discards (see `_on_data_message` in inference_sdk/webrtc/session.py).
    A frame's "errors" entry is what the server reports as that frame's errors:
    the SDK passes the list of strings to `on_error` handlers before `on_data`,
    adding the frame's metadata when the handler takes a second parameter.
    """

    def __init__(self, config, outputs_per_frame, first_frame_id=0):
        self.config = config
        self.outputs_per_frame = outputs_per_frame
        self.first_frame_id = first_frame_id
        self.on_data_handler = None
        self.on_error_handlers = []
        self.closed = False

    def on_data(self, handler):
        self.on_data_handler = handler

    def on_error(self, handler):
        self.on_error_handlers.append(handler)

    def wait(self):
        requested = [*self.config.data_output, *self.config.stream_output]
        for frame_id, outputs in enumerate(self.outputs_per_frame, start=self.first_frame_id):
            metadata = types.SimpleNamespace(frame_id=frame_id)
            errors = outputs.get("errors")
            for handler in self.on_error_handlers if errors else ():
                if len(inspect.signature(handler).parameters) >= 2:
                    handler(errors, metadata)
                else:
                    handler(errors)
            data = {
                name: outputs[name]
                for name in requested
                if name in outputs and name not in self.config.stream_output
            }
            # Like the SDK, pass the frame's metadata only to a handler that
            # takes a second parameter.
            if len(inspect.signature(self.on_data_handler).parameters) >= 2:
                self.on_data_handler(data, metadata)
            else:
                self.on_data_handler(data)

    def close(self):
        self.closed = True


@pytest.fixture
def fake_video_stack(monkeypatch):
    """Stands in for inference-sdk, OpenCV, and NumPy, none of which CI installs."""
    state = {
        "outputs_per_frame": [],
        "sessions": [],
        "written": [],
        "clip_written": [],
        "readable": True,
        "source_frames": 300,
        "first_frame_id": 0,
    }

    class StreamConfig:
        def __init__(self, stream_output=None, data_output=None, **_):
            self.stream_output = list(stream_output or [])
            self.data_output = list(data_output or [])

    class Client:
        def __init__(self, api_url, api_key):
            self.webrtc = self

        def configure(self, configuration):
            return self

        def stream(self, source, workspace, workflow, image_input, config):
            session = _SdkRoutedSession(config, state["outputs_per_frame"], state["first_frame_id"])
            state["sessions"].append(session)
            state["streamed_sources"] = [*state.get("streamed_sources", []), source]
            return session

    class Frame:
        def __init__(self, data):
            self.data = data
            self.shape = (4, 6, 3)

    class Capture:
        def __init__(self, path):
            self.position = 0

        def isOpened(self):
            return state["readable"]

        def read(self):
            if not state["readable"] or self.position >= state["source_frames"]:
                return False, None
            frame = Frame(f"source-{self.position}".encode())
            self.position += 1
            return True, frame

        def set(self, prop, value):
            if prop == "pos_frames":
                self.position = int(value)

        def get(self, prop):
            return {"fps": 30.0, "width": 640.0, "height": 360.0}.get(
                prop, len(state["outputs_per_frame"])
            )

        def release(self):
            pass

    class Writer:
        def __init__(self, path, fourcc, fps, size):
            self.target = state["clip_written"] if str(path).endswith("clip.mp4") else state["written"]

        def isOpened(self):
            return True

        def write(self, frame):
            self.target.append(frame.data)

        def release(self):
            pass

    sdk = types.ModuleType("inference_sdk")
    sdk.InferenceConfiguration = lambda **_: None
    sdk.InferenceHTTPClient = Client
    webrtc = types.ModuleType("inference_sdk.webrtc")
    webrtc.StreamConfig = StreamConfig
    webrtc.VideoFileSource = lambda path, **_: path
    cv2 = types.SimpleNamespace(
        CAP_PROP_FPS="fps",
        CAP_PROP_FRAME_COUNT="count",
        CAP_PROP_FRAME_WIDTH="width",
        CAP_PROP_FRAME_HEIGHT="height",
        CAP_PROP_POS_FRAMES="pos_frames",
        IMREAD_COLOR=1,
        VideoCapture=Capture,
        VideoWriter=Writer,
        VideoWriter_fourcc=lambda *_: 0,
        imdecode=lambda data, flags: Frame(data),
    )
    numpy = types.SimpleNamespace(frombuffer=lambda data, dtype: bytes(data), uint8="uint8")
    for name, module in (
        ("inference_sdk", sdk),
        ("inference_sdk.webrtc", webrtc),
        ("cv2", cv2),
        ("numpy", numpy),
    ):
        monkeypatch.setitem(sys.modules, name, module)
    return state


def _run_processor(tmp_path, clip=None):
    settings = Settings(app_api_key="test-key", base_dir=tmp_path, roboflow_api_key="server-only")
    source = tmp_path / "throw.mp4"
    source.write_bytes(VIDEO)
    return RoboflowVideoProcessor(settings)(
        source, tmp_path / "result.mp4", threading.Event(), lambda *_: None, clip=clip
    )


def test_annotated_frames_reach_the_mp4_through_the_sdk(tmp_path, fake_video_stack):
    fake_video_stack["outputs_per_frame"] = [
        {"output_image": _image("frame-0"), "disc_detections": {"predictions": [{"x": 1}]}},
        {"output_image": _image("frame-1"), "disc_detections": {"predictions": []}},
        {"output_image": _image("frame-2"), "disc_detections": {"predictions": [{"x": 3}]}},
    ]
    summary = _run_processor(tmp_path)
    track = summary.pop("track")
    assert fake_video_stack["written"] == [b"frame-0", b"frame-1", b"frame-2"]
    assert summary == {"framesWithDetections": 2, "detectionRate": 0.667, "frameErrors": 0}
    # A prediction without a full box counts as a detection but has no position.
    assert track == {"fps": 30.0, "frameCount": 3, "detections": []}
    [session] = fake_video_stack["sessions"]
    assert session.closed


def _box(x, y, width, height, confidence):
    return {"x": x, "y": y, "width": width, "height": height, "confidence": confidence, "class": "disc"}


def test_the_track_holds_one_normalized_box_per_frame(tmp_path, fake_video_stack):
    # inference-sdk numbers frames from 1; the track numbers them from 0.
    fake_video_stack["first_frame_id"] = 1
    fake_video_stack["outputs_per_frame"] = [
        {
            "output_image": _image("frame-0"),
            # The tracker's box wins over a raw detection, and is scaled by
            # the image size the Workflow reports.
            "tracked_disc": {
                "image": {"width": 1280, "height": 720},
                "predictions": [_box(640, 180, 32, 18, 0.6)],
            },
            "disc_detections": {"predictions": [_box(10, 10, 5, 5, 0.99)]},
        },
        {
            "output_image": _image("frame-1"),
            "tracked_disc": {"predictions": []},
            # Without an image size, the frame's own 640x360 is the scale.
            "disc_detections": {
                "value": {"predictions": [_box(64, 36, 6.4, 3.6, 0.4), _box(320, 180, 64, 36, 0.9)]}
            },
        },
        {"output_image": _image("frame-2"), "disc_detections": {"predictions": []}},
    ]

    track = _run_processor(tmp_path)["track"]

    assert track == {
        "fps": 30.0,
        "frameCount": 3,
        "detections": [
            {"frame": 0, "timeMs": 0, "x": 0.5, "y": 0.25, "width": 0.025, "height": 0.025, "confidence": 0.6},
            {"frame": 1, "timeMs": 33, "x": 0.5, "y": 0.5, "width": 0.1, "height": 0.1, "confidence": 0.9},
        ],
    }


def test_only_the_clip_is_streamed_to_roboflow(tmp_path, fake_video_stack):
    fake_video_stack["outputs_per_frame"] = [{"output_image": _image("frame-0")}]

    _run_processor(tmp_path, clip=(1000, 2000))

    # 1.0-2.0 s at 30 fps is frames 30 through 60 of the upload.
    assert fake_video_stack["clip_written"] == [f"source-{i}".encode() for i in range(30, 61)]
    assert fake_video_stack["streamed_sources"][-1].endswith("clip.mp4")
    assert not (tmp_path / "clip.mp4").exists()


def test_an_open_ended_clip_runs_to_the_end_of_the_upload(tmp_path, fake_video_stack):
    fake_video_stack["outputs_per_frame"] = [{"output_image": _image("frame-0")}]

    _run_processor(tmp_path, clip=(9000, None))

    assert fake_video_stack["clip_written"] == [f"source-{i}".encode() for i in range(270, 300)]


def test_a_clip_past_the_end_of_the_upload_is_rejected(tmp_path, fake_video_stack):
    with pytest.raises(EmptyClip, match="has no frames"):
        _run_processor(tmp_path, clip=(20_000, 30_000))
    assert fake_video_stack["sessions"] == []


def test_session_without_frames_names_the_reason(tmp_path, fake_video_stack):
    fake_video_stack["outputs_per_frame"] = []
    with pytest.raises(NoAnnotatedFrames, match="processed no frames"):
        _run_processor(tmp_path)

    fake_video_stack["outputs_per_frame"] = [{"disc_detections": {"predictions": []}}] * 2
    with pytest.raises(NoAnnotatedFrames, match="returned 2 frames without an output_image"):
        _run_processor(tmp_path)


def test_unreadable_upload_is_rejected_before_a_session_opens(tmp_path, fake_video_stack):
    fake_video_stack["readable"] = False
    with pytest.raises(UnreadableVideo, match="not a readable video file"):
        _run_processor(tmp_path)
    assert fake_video_stack["sessions"] == []


def test_server_reported_frame_errors_are_logged_without_the_key(
    tmp_path, fake_video_stack, caplog
):
    leaked = "404 for https://api.roboflow.com/model?api_key=server-only"
    fake_video_stack["outputs_per_frame"] = [
        {"output_image": _image("frame-0")},
        {"output_image": _image("frame-1"), "errors": ["tracked_disc: boom", leaked, "x" * 600]},
    ]
    with caplog.at_level(logging.WARNING, logger="disc_flight_school.disc_flight"):
        summary = _run_processor(tmp_path)
    assert summary["frameErrors"] == 1
    [event] = [json.loads(record.getMessage()) for record in caplog.records]
    assert event["event"] == "disc_flight.webrtc_frame_error"
    assert event["frame_id"] == 1
    assert event["errors"][0] == "tracked_disc: boom"
    assert event["errors"][1] == "404 for https://api.roboflow.com/model?api_key=[redacted]"
    assert len(event["errors"][2]) == 500
    assert "server-only" not in caplog.text
