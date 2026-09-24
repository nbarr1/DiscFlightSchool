from __future__ import annotations

import base64
import inspect
import json
import logging
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
    NoAnnotatedFrames,
    RoboflowVideoProcessor,
)
from training_server.storage import FileStorage


VIDEO = b"\x00\x00\x00\x18ftypmp42" + b"video-data"
AUTH = {"X-App-Key": "test-key"}


class FakeProcessor:
    def __init__(self, mode="success"):
        self.mode = mode
        self.closed = False

    def __call__(self, source, destination, cancel, update):
        update(1, 2, "processing")
        if self.mode == "failure":
            raise ConnectionError("secret upstream detail")
        if self.mode == "no-frames":
            raise NoAnnotatedFrames("Roboflow processed no frames.")
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
        }

    def close(self):
        self.closed = True


def make_client(tmp_path: Path, mode="success", *, max_bytes=1024):
    settings = Settings(
        app_api_key="test-key",
        base_dir=tmp_path,
        roboflow_api_key="server-only",
        disc_flight_max_upload_bytes=max_bytes,
    )
    manager = DiscFlightJobManager(settings, lambda: FakeProcessor(mode))
    app = create_app(settings, FileStorage(settings), manager)
    return TestClient(app), manager


def start(client: TestClient, data=VIDEO, content_type="video/mp4", filename="throw.mp4"):
    return client.post(
        "/api/disc-flight/jobs",
        headers=AUTH,
        files={"video": (filename, data, content_type)},
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

    def __init__(self, config, outputs_per_frame):
        self.config = config
        self.outputs_per_frame = outputs_per_frame
        self.on_data_handler = None
        self.on_error_handlers = []
        self.closed = False

    def on_data(self, handler):
        self.on_data_handler = handler

    def on_error(self, handler):
        self.on_error_handlers.append(handler)

    def wait(self):
        requested = [*self.config.data_output, *self.config.stream_output]
        for frame_id, outputs in enumerate(self.outputs_per_frame):
            errors = outputs.get("errors")
            for handler in self.on_error_handlers if errors else ():
                if len(inspect.signature(handler).parameters) >= 2:
                    handler(errors, types.SimpleNamespace(frame_id=frame_id))
                else:
                    handler(errors)
            self.on_data_handler(
                {
                    name: outputs[name]
                    for name in requested
                    if name in outputs and name not in self.config.stream_output
                }
            )

    def close(self):
        self.closed = True


@pytest.fixture
def fake_video_stack(monkeypatch):
    """Stands in for inference-sdk, OpenCV, and NumPy, none of which CI installs."""
    state = {"outputs_per_frame": [], "sessions": [], "written": []}

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
            session = _SdkRoutedSession(config, state["outputs_per_frame"])
            state["sessions"].append(session)
            return session

    class Frame:
        def __init__(self, data):
            self.data = data
            self.shape = (4, 6, 3)

    class Capture:
        def __init__(self, path):
            pass

        def get(self, prop):
            return 30.0 if prop == "fps" else len(state["outputs_per_frame"])

        def release(self):
            pass

    class Writer:
        def __init__(self, path, fourcc, fps, size):
            pass

        def isOpened(self):
            return True

        def write(self, frame):
            state["written"].append(frame.data)

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


def _run_processor(tmp_path):
    settings = Settings(app_api_key="test-key", base_dir=tmp_path, roboflow_api_key="server-only")
    source = tmp_path / "throw.mp4"
    source.write_bytes(VIDEO)
    return RoboflowVideoProcessor(settings)(
        source, tmp_path / "result.mp4", threading.Event(), lambda *_: None
    )


def test_annotated_frames_reach_the_mp4_through_the_sdk(tmp_path, fake_video_stack):
    fake_video_stack["outputs_per_frame"] = [
        {"output_image": _image("frame-0"), "disc_detections": {"predictions": [{"x": 1}]}},
        {"output_image": _image("frame-1"), "disc_detections": {"predictions": []}},
        {"output_image": _image("frame-2"), "disc_detections": {"predictions": [{"x": 3}]}},
    ]
    summary = _run_processor(tmp_path)
    assert fake_video_stack["written"] == [b"frame-0", b"frame-1", b"frame-2"]
    assert summary == {"framesWithDetections": 2, "detectionRate": 0.667, "frameErrors": 0}
    [session] = fake_video_stack["sessions"]
    assert session.closed


def test_session_without_frames_names_the_reason(tmp_path, fake_video_stack):
    fake_video_stack["outputs_per_frame"] = []
    with pytest.raises(NoAnnotatedFrames, match="processed no frames"):
        _run_processor(tmp_path)

    fake_video_stack["outputs_per_frame"] = [{"disc_detections": {"predictions": []}}] * 2
    with pytest.raises(NoAnnotatedFrames, match="returned 2 frames without an output_image"):
        _run_processor(tmp_path)


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
