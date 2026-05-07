import asyncio
import json
import os
import tempfile
import unittest
from pathlib import Path

os.environ.setdefault("APP_API_KEY", "test-key")

from training_server import Settings, create_app  # noqa: E402


class AsgiResponse:
    def __init__(self, status_code: int, headers: list[tuple[bytes, bytes]], body: bytes) -> None:
        self.status_code = status_code
        self.headers = headers
        self.body = body

    def json(self) -> dict:
        return json.loads(self.body.decode())


async def call_asgi(app, method: str, path: str, *, headers: dict[str, str] | None = None, body: bytes = b"") -> AsgiResponse:
    request_sent = False
    sent_events = []
    raw_headers = [(key.lower().encode(), value.encode()) for key, value in (headers or {}).items()]
    if body and not any(key == b"content-length" for key, _ in raw_headers):
        raw_headers.append((b"content-length", str(len(body)).encode()))

    scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": method,
        "scheme": "http",
        "path": path,
        "raw_path": path.encode(),
        "query_string": b"",
        "headers": raw_headers,
        "client": ("testclient", 50000),
        "server": ("testserver", 80),
    }

    async def receive():
        nonlocal request_sent
        if request_sent:
            return {"type": "http.disconnect"}
        request_sent = True
        return {"type": "http.request", "body": body, "more_body": False}

    async def send(message):
        sent_events.append(message)

    await app(scope, receive, send)
    start = next(event for event in sent_events if event["type"] == "http.response.start")
    response_body = b"".join(
        event.get("body", b"") for event in sent_events if event["type"] == "http.response.body"
    )
    return AsgiResponse(start["status"], start.get("headers", []), response_body)


def multipart_body(fields: dict[str, str], files: dict[str, tuple[str, bytes, str]]) -> tuple[bytes, str]:
    boundary = "----DiscFlightSchoolBoundary"
    chunks: list[bytes] = []
    for name, value in fields.items():
        chunks.extend(
            [
                f"--{boundary}\r\n".encode(),
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode(),
                value.encode(),
                b"\r\n",
            ]
        )
    for name, (filename, content, content_type) in files.items():
        chunks.extend(
            [
                f"--{boundary}\r\n".encode(),
                f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'.encode(),
                f"Content-Type: {content_type}\r\n\r\n".encode(),
                content,
                b"\r\n",
            ]
        )
    chunks.append(f"--{boundary}--\r\n".encode())
    return b"".join(chunks), f"multipart/form-data; boundary={boundary}"


class TrainingServerContractTests(unittest.TestCase):
    def build_app(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        settings = Settings(app_api_key="test-key", base_dir=Path(self.tmpdir.name), max_upload_bytes=1024)
        return create_app(settings)

    def tearDown(self) -> None:
        if hasattr(self, "tmpdir"):
            self.tmpdir.cleanup()

    def request(self, app, method: str, path: str, **kwargs) -> AsgiResponse:
        return asyncio.run(call_asgi(app, method, path, **kwargs))

    def test_health_and_no_model_version_contracts(self):
        app = self.build_app()
        self.assertEqual(self.request(app, "GET", "/health").json(), {"status": "ok"})
        self.assertEqual(
            self.request(app, "GET", "/api/model/version").json(),
            {"version": "none", "sha256": "", "url": ""},
        )
        self.assertEqual(self.request(app, "GET", "/api/model/download").status_code, 404)

    def test_upload_requires_api_key(self):
        app = self.build_app()
        body, content_type = multipart_body(
            {"sample_id": "sample-1", "label": "0 0.5 0.5 0.1 0.1", "image_width": "100", "image_height": "100"},
            {
                "full_image": ("full.jpg", b"\xff\xd8\xff\x00", "image/jpeg"),
                "crop_image": ("crop.jpg", b"\xff\xd8\xff\x00", "image/jpeg"),
            },
        )
        response = self.request(app, "POST", "/api/training/upload", headers={"content-type": content_type}, body=body)
        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.json(), {"error": "Invalid or missing API key"})

    def test_upload_rejects_invalid_label_before_file_write(self):
        app = self.build_app()
        body, content_type = multipart_body(
            {"sample_id": "sample-1", "label": "1 0.5 0.5 0.1 0.1", "image_width": "100", "image_height": "100"},
            {
                "full_image": ("full.jpg", b"\xff\xd8\xff\x00", "image/jpeg"),
                "crop_image": ("crop.jpg", b"\xff\xd8\xff\x00", "image/jpeg"),
            },
        )
        response = self.request(
            app,
            "POST",
            "/api/training/upload",
            headers={"content-type": content_type, "x-app-key": "test-key"},
            body=body,
        )
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json(), {"error": "label must be a single YOLO class-0 row with normalized values"})

    def test_upload_accepts_valid_sample_and_updates_stats(self):
        app = self.build_app()
        body, content_type = multipart_body(
            {"sample_id": "sample-1", "label": "0 0.5 0.5 0.1 0.1", "image_width": "100", "image_height": "100"},
            {
                "full_image": ("full.jpg", b"\xff\xd8\xff\x00", "image/jpeg"),
                "crop_image": ("crop.png", b"\x89PNG\r\n\x1a\n\x00", "image/png"),
            },
        )
        response = self.request(
            app,
            "POST",
            "/api/training/upload",
            headers={"content-type": content_type, "x-app-key": "test-key"},
            body=body,
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "ok")

        stats = self.request(app, "GET", "/api/training/stats").json()
        self.assertEqual(stats["total_samples"], 1)
        self.assertEqual(stats["images_on_disk"], 1)
        self.assertEqual(stats["labels_on_disk"], 1)


if __name__ == "__main__":
    unittest.main()
