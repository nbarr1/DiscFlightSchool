#!/usr/bin/env python3
"""Run one video through a deployed server's disc-flight endpoints.

The Roboflow smoke test (test_roboflow_integration.py) calls the Workflow
directly, so it passes even when the deployed server cannot reach Roboflow.
This script goes through the server the app uses instead: it uploads a clip
the way the app does, polls the job, and fetches the track, printing what the
server answered at each step. It spends Roboflow credits for every frame of
the clip, so use a short one.

    DISC_FLIGHT_SERVER_URL=https://discflightschool-1.onrender.com \
    DISC_FLIGHT_API_KEY=... \
    python scripts/check_deployed_disc_flight.py clip.mp4

DISC_FLIGHT_API_KEY is APP_API_KEY or CLIENT_API_KEY. Only the standard
library is used, so this runs anywhere Python 3.9+ does.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

# A sleeping Render service takes a minute or more to wake on its first request.
REQUEST_TIMEOUT_SECONDS = 180
POLL_SECONDS = 2
JOB_TIMEOUT_SECONDS = 15 * 60


def request(method: str, url: str, *, headers: dict[str, str], body: bytes | None = None):
    """(status, parsed JSON or text) for one request. HTTP errors are returned, not raised."""
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            status, raw = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, raw = error.code, error.read()
    try:
        return status, json.loads(raw)
    except ValueError:
        return status, raw[:300].decode("utf-8", "replace")


def multipart(video: Path) -> tuple[bytes, str]:
    boundary = uuid.uuid4().hex
    head = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="video"; filename="{video.name}"\r\n'
        "Content-Type: video/mp4\r\n\r\n"
    ).encode()
    return head + video.read_bytes() + f"\r\n--{boundary}--\r\n".encode(), boundary


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: check_deployed_disc_flight.py <clip.mp4>")
    base = os.environ.get("DISC_FLIGHT_SERVER_URL", "").rstrip("/")
    key = os.environ.get("DISC_FLIGHT_API_KEY", "")
    if not base or not key:
        raise SystemExit("Set DISC_FLIGHT_SERVER_URL and DISC_FLIGHT_API_KEY.")
    video = Path(sys.argv[1])

    started = time.monotonic()
    status, body = request("GET", f"{base}/", headers={})
    print(f"GET / -> {status} ({time.monotonic() - started:.1f}s, includes any cold start)")
    # The endpoint list says which release is deployed: one without
    # /ready or .../track predates this repository's main branch.
    endpoints = body.get("endpoints") if isinstance(body, dict) else None
    for endpoint in endpoints or [body]:
        print(f"  {endpoint}")
    status, body = request("GET", f"{base}/ready", headers={})
    print(f"GET /ready -> {status} {body}")

    payload, boundary = multipart(video)
    status, body = request(
        "POST",
        f"{base}/api/disc-flight/jobs",
        headers={"X-App-Key": key, "Content-Type": f"multipart/form-data; boundary={boundary}"},
        body=payload,
    )
    print(f"POST /api/disc-flight/jobs ({len(payload)} bytes) -> {status} {body}")
    if status != 202:
        return 1
    job_id, token = body["jobId"], body["jobToken"]
    auth = {"X-App-Key": key, "X-Job-Token": token}

    deadline = time.monotonic() + JOB_TIMEOUT_SECONDS
    last = None
    while time.monotonic() < deadline:
        status, body = request("GET", f"{base}/api/disc-flight/jobs/{job_id}", headers=auth)
        line = f"{status} {body}"
        if line != last:
            print(f"GET job -> {line}")
            last = line
        if status != 200 or body.get("status") in {"complete", "failed", "cancelled"}:
            break
        time.sleep(POLL_SECONDS)
    else:
        print("The job did not finish in time; cancelling it.")
        request("DELETE", f"{base}/api/disc-flight/jobs/{job_id}", headers=auth)
        return 1
    if status != 200 or body.get("status") != "complete":
        return 1

    status, track = request("GET", f"{base}/api/disc-flight/jobs/{job_id}/track", headers=auth)
    if status != 200 or not isinstance(track, dict):
        print(f"GET track -> {status} {track}")
        return 1
    detections = track.get("detections") or []
    print(
        f"GET track -> {status}: {len(detections)} of {track.get('frameCount')} frames "
        f"have a position at {track.get('fps')} fps"
    )
    request("DELETE", f"{base}/api/disc-flight/jobs/{job_id}", headers=auth)
    return 0


if __name__ == "__main__":
    sys.exit(main())
