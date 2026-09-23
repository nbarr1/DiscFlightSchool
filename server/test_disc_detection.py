from __future__ import annotations

import base64
import json
import sys
import threading
import types
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from training_server import disc_detection
from training_server.disc_detection import (
    DiscDetectionError,
    DiscDetectionInputError,
    DiscDetectionNotConfigured,
    DiscDetectionRequestError,
    DiscDetectionResponseError,
    DiscDetectionTimeout,
    detect_discs,
    parse_disc_detections,
)

# Captured from a real run of the published Workflow on September 23, 2026,
# on a 576x1024 frame from the disc-golf-flight-tracker dataset.
REAL_RESPONSE = [
    {
        "predictions": {
            "image": {"width": 576, "height": 1024},
            "predictions": [
                {
                    "width": 40,
                    "height": 22,
                    "x": 228,
                    "y": 521,
                    "confidence": 0.8215386867523193,
                    "class_id": 0,
                    "class": "disc",
                    "detection_id": "3396dcf8-ae17-4045-976c-d2765f18594d",
                    "parent_id": "image",
                }
            ],
        }
    }
]
IMAGE = b"\xff\xd8\xff\xe0jpeg-bytes"


def _sdk_errors(monkeypatch):
    """The SDK's error classes, or stand-ins with the same shape when it isn't installed.

    CI installs requirements-test.txt, which leaves inference-sdk out.
    """
    try:
        from inference_sdk.http import errors
    except ImportError:
        errors = types.ModuleType("inference_sdk.http.errors")

        class HTTPClientError(Exception):
            pass

        class HTTPCallErrorError(HTTPClientError):
            def __init__(self, description, status_code, api_message):
                super().__init__(description)
                self.status_code = status_code

        class InvalidInputFormatError(HTTPClientError):
            pass

        errors.HTTPClientError = HTTPClientError
        errors.HTTPCallErrorError = HTTPCallErrorError
        errors.InvalidInputFormatError = InvalidInputFormatError
        http = types.ModuleType("inference_sdk.http")
        http.errors = errors
        monkeypatch.setitem(sys.modules, "inference_sdk", types.ModuleType("inference_sdk"))
        monkeypatch.setitem(sys.modules, "inference_sdk.http", http)
        monkeypatch.setitem(sys.modules, "inference_sdk.http.errors", errors)
    return errors


class FakeClient:
    """Plays back one scripted outcome per call: a result, or an exception to raise."""

    def __init__(self, *outcomes):
        self.outcomes = list(outcomes)
        self.calls = []

    def run_workflow(self, **kwargs):
        self.calls.append(kwargs)
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        if callable(outcome):
            return outcome()
        return outcome


@pytest.fixture
def use_client(monkeypatch):
    monkeypatch.setattr(disc_detection, "RETRY_BACKOFF_SECONDS", 0)

    def install(client):
        monkeypatch.setattr(disc_detection, "_build_client", lambda api_key, api_url: client)
        return client

    return install


def test_parses_real_workflow_response(use_client):
    client = use_client(FakeClient(REAL_RESPONSE))
    result = detect_discs(IMAGE, api_key="server-only")

    assert (result.image_width, result.image_height) == (576, 1024)
    assert len(result.detections) == 1
    box = result.detections[0]
    assert (box.x, box.y, box.width, box.height) == (228, 521, 40, 22)
    assert box.class_name == "disc"
    assert box.confidence == pytest.approx(0.8215, abs=1e-4)
    # The published Workflow declares no runtime parameters, so none are sent.
    assert client.calls == [
        {
            "workspace_name": "disc-golf-tracer",
            "workflow_id": "disc-golf-flight-tracker-vdisc-golf-flight-tracker-2-rfdetr-small-t1-logic",
            "images": {"image": base64.b64encode(IMAGE).decode()},
        }
    ]


def test_empty_prediction_list_is_not_an_error():
    outputs = {"predictions": {"image": {"width": 640, "height": 360}, "predictions": []}}
    assert parse_disc_detections(outputs).detections == ()


def test_malformed_boxes_are_skipped():
    good = REAL_RESPONSE[0]["predictions"]["predictions"][0]
    outputs = {
        "predictions": {
            "image": {"width": 576, "height": 1024},
            "predictions": [good, {"x": "228", "class": "disc"}, None, {**good, "confidence": True}],
        }
    }
    assert len(parse_disc_detections(outputs).detections) == 1


@pytest.mark.parametrize(
    "outputs",
    [
        {"output_image": "base64"},
        {"predictions": []},
        {"predictions": {"predictions": []}},
        {"predictions": {"image": {"width": 1, "height": 1}}},
    ],
)
def test_unexpected_output_shape_names_what_was_returned(outputs):
    with pytest.raises(DiscDetectionResponseError) as raised:
        parse_disc_detections(outputs)
    assert "predictions" in str(raised.value)


def test_missing_api_key_fails_before_any_request(use_client):
    client = use_client(FakeClient())
    with pytest.raises(DiscDetectionNotConfigured):
        detect_discs(IMAGE, api_key=None)
    assert client.calls == []


@pytest.mark.parametrize("image", ["http://example.com/throw.jpg", "does-not-exist.jpg", b""])
def test_unusable_image_is_rejected_locally(use_client, image):
    client = use_client(FakeClient())
    with pytest.raises(DiscDetectionInputError):
        detect_discs(image, api_key="server-only")
    assert client.calls == []


def test_file_path_and_https_url_inputs(use_client, tmp_path):
    path = tmp_path / "frame.jpg"
    path.write_bytes(IMAGE)
    client = use_client(FakeClient(REAL_RESPONSE, REAL_RESPONSE))
    detect_discs(path, api_key="server-only")
    detect_discs("https://example.com/frame.jpg", api_key="server-only")
    assert client.calls[0]["images"] == {"image": base64.b64encode(IMAGE).decode()}
    assert client.calls[1]["images"] == {"image": "https://example.com/frame.jpg"}


def test_transient_failures_are_retried(use_client, monkeypatch):
    errors = _sdk_errors(monkeypatch)
    client = use_client(
        FakeClient(
            errors.HTTPClientError("Error with server connection"),
            errors.HTTPCallErrorError("busy", 503, None),
            REAL_RESPONSE,
        )
    )
    assert len(detect_discs(IMAGE, api_key="server-only").detections) == 1
    assert len(client.calls) == 3


def test_retries_are_bounded(use_client, monkeypatch):
    errors = _sdk_errors(monkeypatch)
    client = use_client(FakeClient(*[errors.HTTPCallErrorError("busy", 429, None)] * 3))
    with pytest.raises(DiscDetectionRequestError) as raised:
        detect_discs(IMAGE, api_key="server-only", retries=2)
    assert raised.value.status_code == 429
    assert len(client.calls) == 3


@pytest.mark.parametrize("status", [400, 401, 403, 404])
def test_client_errors_are_not_retried(use_client, monkeypatch, status):
    errors = _sdk_errors(monkeypatch)
    client = use_client(FakeClient(errors.HTTPCallErrorError("no", status, None)))
    with pytest.raises(DiscDetectionRequestError) as raised:
        detect_discs(IMAGE, api_key="server-only")
    assert raised.value.status_code == status
    assert len(client.calls) == 1


def test_sdk_input_error_is_typed_and_not_retried(use_client, monkeypatch):
    errors = _sdk_errors(monkeypatch)
    client = use_client(FakeClient(errors.InvalidInputFormatError("bad image")))
    with pytest.raises(DiscDetectionInputError):
        detect_discs(IMAGE, api_key="server-only")
    assert len(client.calls) == 1


def test_each_attempt_times_out(use_client):
    release = threading.Event()
    client = use_client(FakeClient(release.wait, release.wait))
    try:
        with pytest.raises(DiscDetectionTimeout):
            detect_discs(IMAGE, api_key="server-only", timeout_seconds=0.05, retries=1)
    finally:
        release.set()
    assert len(client.calls) == 2


def test_timeout_is_a_detection_error_and_a_timeout_error():
    assert issubclass(DiscDetectionTimeout, DiscDetectionError)
    assert issubclass(DiscDetectionTimeout, TimeoutError)


class _StubWorkflowServer:
    """A local HTTP server standing in for serverless.roboflow.com."""

    def __init__(self, statuses):
        self.statuses = list(statuses)
        self.requests = []
        stub = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                stub.requests.append((self.path, dict(self.headers), body))
                status = stub.statuses.pop(0)
                payload = {"outputs": REAL_RESPONSE} if status == 200 else {"message": "stub"}
                encoded = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


@pytest.fixture
def stub_server(monkeypatch):
    pytest.importorskip("inference_sdk")
    monkeypatch.setattr(disc_detection, "RETRY_BACKOFF_SECONDS", 0)
    for name in ("NO_PROXY", "no_proxy"):
        monkeypatch.setenv(name, "127.0.0.1,localhost")
    servers = []

    def start(*statuses):
        servers.append(_StubWorkflowServer(statuses))
        return servers[-1]

    yield start
    for server in servers:
        server.close()


def test_real_sdk_sends_key_in_header_only(stub_server):
    server = stub_server(200)
    result = detect_discs(IMAGE, api_key="secret-test-key", api_url=server.url)

    assert len(result.detections) == 1
    [(path, headers, body)] = server.requests
    assert path == (
        "/disc-golf-tracer/workflows/"
        "disc-golf-flight-tracker-vdisc-golf-flight-tracker-2-rfdetr-small-t1-logic"
    )
    assert headers["Authorization"] == "Bearer secret-test-key"
    assert "secret-test-key" not in path
    assert "secret-test-key" not in json.dumps(body)
    assert body["inputs"] == {
        "image": {"type": "base64", "value": base64.b64encode(IMAGE).decode()}
    }


def test_real_sdk_retries_503_but_not_401(stub_server):
    retried = stub_server(503, 200)
    detect_discs(IMAGE, api_key="secret-test-key", api_url=retried.url)
    assert len(retried.requests) == 2

    rejected = stub_server(401)
    with pytest.raises(DiscDetectionRequestError) as raised:
        detect_discs(IMAGE, api_key="secret-test-key", api_url=rejected.url)
    assert raised.value.status_code == 401
    assert "secret-test-key" not in str(raised.value)
    assert len(rejected.requests) == 1


def test_real_sdk_does_not_stack_its_own_retries(stub_server):
    server = stub_server(503, 503, 503)
    with pytest.raises(DiscDetectionRequestError):
        detect_discs(IMAGE, api_key="secret-test-key", api_url=server.url, retries=0)
    assert len(server.requests) == 1
