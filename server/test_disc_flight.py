from __future__ import annotations

import time
from pathlib import Path

from fastapi.testclient import TestClient

from training_server import Settings, create_app
from training_server.disc_flight import Cancelled, DiscFlightJobManager
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
