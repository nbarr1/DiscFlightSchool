"""Stateful Roboflow video processing and short-lived job ownership.

The Roboflow imports are intentionally lazy: normal server tests and training
workers do not need the WebRTC/OpenCV runtime, and tests inject a processor so
they can never spend inference credits.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import secrets
import shutil
import statistics
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Protocol

from .config import Settings

logger = logging.getLogger("disc_flight_school.disc_flight")

ALLOWED_VIDEO_TYPES = {
    "video/mp4": ".mp4",
    "video/quicktime": ".mov",
    "video/webm": ".webm",
    "video/x-matroska": ".mkv",
}
WORKSPACE = "disc-golf-tracer"
WORKFLOW = "disc-golf-flight-tracker-1789645514948"
IMAGE_INPUT = "image"


class Cancelled(Exception):
    """Raised when a caller cancels an active inference session."""


class VideoProcessor(Protocol):
    def __call__(
        self,
        source: Path,
        destination: Path,
        cancel: threading.Event,
        update: Callable[[int, int | None, str], None],
    ) -> dict[str, Any]: ...


@dataclass
class DiscFlightJob:
    id: str
    owner_hash: str
    directory: Path
    input_path: Path
    output_path: Path
    source_hash: str = ""
    status: str = "queued"
    frames_processed: int = 0
    total_frames: int | None = None
    summary: dict[str, Any] | None = None
    error: str | None = None
    cancel_event: threading.Event = field(default_factory=threading.Event, repr=False)
    session: Any = field(default=None, repr=False)

    def public(self) -> dict[str, Any]:
        body: dict[str, Any] = {
            "jobId": self.id,
            "status": self.status,
            "framesProcessed": self.frames_processed,
        }
        if self.total_frames is not None:
            body["totalFrames"] = self.total_frames
            body["progress"] = min(1.0, self.frames_processed / max(1, self.total_frames))
        if self.status == "complete":
            body["resultVideoUrl"] = f"/api/disc-flight/jobs/{self.id}/result"
            body["summary"] = self.summary or {}
        if self.error:
            body["error"] = self.error
        return body


class RoboflowVideoProcessor:
    """Runs a whole file through one WebRTC workflow session."""

    def __init__(self, settings: Settings):
        self.settings = settings
        self.active_session: Any = None

    def close(self) -> None:
        session = self.active_session
        if session is not None:
            for method in ("stop", "close"):
                closer = getattr(session, method, None)
                if callable(closer):
                    closer()
                    break

    def __call__(self, source, destination, cancel, update):
        if not self.settings.roboflow_api_key:
            raise RuntimeError("Roboflow processing is not configured on this server")

        import cv2
        import numpy as np
        from inference_sdk import InferenceConfiguration, InferenceHTTPClient
        from inference_sdk.webrtc import StreamConfig, VideoFileSource

        capture = cv2.VideoCapture(str(source))
        input_fps = capture.get(cv2.CAP_PROP_FPS) or 30.0
        reliable_total = int(capture.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
        capture.release()
        total = reliable_total if reliable_total > 0 else None

        # Keep only small frame metadata in memory. Annotated images can be
        # several megabytes once decoded, so retaining a video's worth of
        # NumPy arrays here would allow an otherwise valid upload to exhaust
        # the API worker's memory.
        frames: list[tuple[int, float | None, Path]] = []
        detection_frames: set[int] = set()
        frame_errors: list[str] = []
        frames_lock = threading.Lock()

        def on_data(data: dict[str, Any]) -> None:
            if cancel.is_set():
                self.close()
                return
            try:
                with frames_lock:
                    default_frame_id = len(frames)
                frame_id = _frame_id(data, default_frame_id)
                timestamp = _timestamp(data)
                encoded = _output_value(data.get("output_image"))
                if encoded:
                    compressed = base64.b64decode(encoded)
                    decoded = cv2.imdecode(
                        np.frombuffer(compressed, dtype=np.uint8),
                        cv2.IMREAD_COLOR,
                    )
                    if decoded is not None:
                        # Preserve the compressed workflow output on disk and
                        # release the decoded frame immediately. It is decoded
                        # again, one frame at a time, while assembling the MP4.
                        frame_path = spool_directory / f"{uuid.uuid4().hex}.image"
                        frame_path.write_bytes(compressed)
                        with frames_lock:
                            frames.append((frame_id, timestamp, frame_path))
                with frames_lock:
                    if _prediction_count(data.get("disc_detections")) > 0:
                        detection_frames.add(frame_id)
                    completed = len(frames)
                update(completed, total, "processing")
            except Exception as exc:  # one malformed frame must not end a throw
                frame_errors.append(f"frame {_frame_id(data, len(frames))}: {type(exc).__name__}")
                logger.warning(json.dumps({"event": "disc_flight.frame_error", "error": type(exc).__name__}))

        def on_error(error: Any) -> None:
            frame_errors.append(type(error).__name__)
            logger.warning(json.dumps({"event": "disc_flight.webrtc_frame_error", "error": type(error).__name__}))

        client = InferenceHTTPClient(
            api_url="https://serverless.roboflow.com",
            api_key=self.settings.roboflow_api_key,
        ).configure(InferenceConfiguration(api_key_transport="header"))
        source_stream = VideoFileSource(str(source), realtime_processing=False)
        session = client.webrtc.stream(
            source=source_stream,
            workspace=WORKSPACE,
            workflow=WORKFLOW,
            image_input=IMAGE_INPUT,
            config=StreamConfig(
                stream_output=[],
                data_output=["output_image", "disc_detections", "tracked_disc"],
                # Must match the source's flag. The source's value is what the
                # server is told; this one is what the client uses to decide
                # whether to acknowledge frames. Left at its default the two
                # disagree: the server queues every frame while the client
                # sends no acknowledgements back.
                realtime_processing=False,
            ),
        )
        self.active_session = session
        _register_callback(session, "data", on_data)
        _register_callback(session, "error", on_error)
        spool = tempfile.TemporaryDirectory(prefix="annotated-frames-", dir=destination.parent)
        spool_directory = Path(spool.name)
        started = time.monotonic()
        timed_out = threading.Event()
        timer: threading.Timer | None = None

        def expire_session() -> None:
            timed_out.set()
            self.close()

        try:
            update(0, total, "connecting")
            timer = threading.Timer(self.settings.disc_flight_session_timeout_seconds, expire_session)
            timer.daemon = True
            timer.start()
            starter = getattr(session, "start", None)
            if callable(starter):
                starter()
            waiter = getattr(session, "join", None) or getattr(session, "wait", None)
            if not callable(waiter):
                raise RuntimeError("Installed inference-sdk session cannot be awaited")
            # SDK implementations enforce their own media timeout; additionally
            # reject a call that returns after our configured wall-clock limit.
            waiter()
            if timed_out.is_set() or time.monotonic() - started > self.settings.disc_flight_session_timeout_seconds:
                raise TimeoutError("Roboflow session timed out")
            if cancel.is_set():
                raise Cancelled()
            update(len(frames), total, "finalizing")
            _write_mp4(frames, destination, input_fps, cv2, np)
        finally:
            if timer is not None:
                timer.cancel()
            self.close()
            self.active_session = None
            spool.cleanup()

        count = len(frames)
        return {
            "framesWithDetections": len(detection_frames),
            "detectionRate": round(len(detection_frames) / count, 3) if count else 0.0,
            "frameErrors": len(frame_errors),
        }


class DiscFlightJobManager:
    def __init__(self, settings: Settings, processor_factory=None):
        self.settings = settings
        self.root = settings.base_dir / "disc_flight_jobs"
        self.root.mkdir(parents=True, exist_ok=True)
        self.processor_factory = processor_factory or (lambda: RoboflowVideoProcessor(settings))
        self.jobs: dict[str, DiscFlightJob] = {}
        self.lock = threading.Lock()

    @staticmethod
    def token_hash(token: str) -> str:
        return hashlib.sha256(token.encode()).hexdigest()

    def create(self, source: Path, suffix: str, source_hash: str) -> tuple[DiscFlightJob, str]:
        token = secrets.token_urlsafe(32)
        job_id = str(uuid.uuid4())
        directory = self.root / job_id
        directory.mkdir(mode=0o700)
        input_path = directory / f"input{suffix}"
        shutil.move(str(source), input_path)
        job = DiscFlightJob(
            job_id, self.token_hash(token), directory, input_path, directory / "result.mp4", source_hash
        )
        with self.lock:
            if any(
                existing.source_hash == source_hash
                and existing.status not in {"complete", "failed", "cancelled"}
                for existing in self.jobs.values()
            ):
                shutil.rmtree(directory, ignore_errors=True)
                raise ValueError("This video already has an active processing job")
            self.jobs[job_id] = job
        threading.Thread(target=self._run, args=(job,), daemon=True).start()
        return job, token

    def get(self, job_id: str, token: str | None) -> DiscFlightJob | None:
        with self.lock:
            job = self.jobs.get(job_id)
        if job is None or not token or not secrets.compare_digest(job.owner_hash, self.token_hash(token)):
            return None
        return job

    def cancel(self, job: DiscFlightJob) -> None:
        job.cancel_event.set()
        close = getattr(job.session, "close", None)
        if callable(close):
            close()
        if job.status not in {"complete", "failed", "cancelled"}:
            job.status = "cancelled"
        self._cleanup_input(job)

    def _run(self, job: DiscFlightJob) -> None:
        processor = self.processor_factory()
        job.session = processor

        def update(done: int, total: int | None, status: str) -> None:
            if job.cancel_event.is_set():
                raise Cancelled()
            job.frames_processed = done
            job.total_frames = total
            job.status = status

        try:
            job.status = "connecting"
            job.summary = processor(job.input_path, job.output_path, job.cancel_event, update)
            if job.cancel_event.is_set():
                raise Cancelled()
            job.status = "complete"
        except Cancelled:
            job.status = "cancelled"
            job.output_path.unlink(missing_ok=True)
        except Exception as exc:
            job.status = "failed"
            job.error = _safe_error(exc)
            job.output_path.unlink(missing_ok=True)
            logger.error(json.dumps({"event": "disc_flight.job_failed", "job_id": job.id, "error": type(exc).__name__}))
        finally:
            close = getattr(processor, "close", None)
            if callable(close):
                close()
            job.session = None
            self._cleanup_input(job)

    @staticmethod
    def _cleanup_input(job: DiscFlightJob) -> None:
        job.input_path.unlink(missing_ok=True)
        if job.status != "complete":
            job.output_path.unlink(missing_ok=True)
            try:
                job.directory.rmdir()
            except OSError:
                pass


def _safe_error(exc: Exception) -> str:
    if isinstance(exc, TimeoutError):
        return "Disc processing timed out. Try a shorter video."
    if isinstance(exc, RuntimeError) and "not configured" in str(exc):
        return str(exc)
    return "The disc-flight service could not process this video. Please retry."


def _output_value(value: Any) -> str | None:
    if isinstance(value, str):
        return value
    if isinstance(value, dict) and isinstance(value.get("value"), str):
        return value["value"]
    return None


def _prediction_count(value: Any) -> int:
    value = value.get("value", value) if isinstance(value, dict) else value
    if isinstance(value, dict):
        predictions = value.get("predictions", [])
        return len(predictions) if isinstance(predictions, list) else 0
    return len(value) if isinstance(value, list) else 0


def _frame_id(data: dict[str, Any], default: int) -> int:
    metadata = data.get("video_metadata") or data.get("metadata") or {}
    value = data.get("frame_id", metadata.get("frame_id", default))
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _timestamp(data: dict[str, Any]) -> float | None:
    metadata = data.get("video_metadata") or data.get("metadata") or {}
    value = data.get("timestamp", metadata.get("timestamp"))
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _register_callback(session: Any, event: str, callback: Callable) -> None:
    for name in (f"on_{event}", f"add_{event}_callback"):
        registrar = getattr(session, name, None)
        if callable(registrar):
            registrar(callback)
            return
    registrar = getattr(session, "on", None)
    if callable(registrar):
        registrar(event, callback)
        return
    raise RuntimeError(f"Installed inference-sdk does not expose a {event} callback")


def _write_mp4(frames, destination: Path, fallback_fps: float, cv2: Any, np: Any) -> None:
    if not frames:
        raise RuntimeError("Workflow returned no annotated frames")
    ordered = sorted(frames, key=lambda item: item[0])
    timestamps = [item[1] for item in ordered if item[1] is not None]
    positive_deltas = [b - a for a, b in zip(timestamps, timestamps[1:]) if b > a]
    fps = fallback_fps
    if positive_deltas:
        median = statistics.median(positive_deltas)
        # SDK timestamps may be seconds or milliseconds.
        fps = (1000.0 / median) if median > 1.0 else (1.0 / median)
    fps = min(240.0, max(1.0, fps))
    def decode(path: Path):
        return cv2.imdecode(np.frombuffer(path.read_bytes(), dtype=np.uint8), cv2.IMREAD_COLOR)

    first_frame = decode(ordered[0][2])
    if first_frame is None:
        raise RuntimeError("Could not decode an annotated frame")
    height, width = first_frame.shape[:2]
    writer = cv2.VideoWriter(str(destination), cv2.VideoWriter_fourcc(*"mp4v"), fps, (width, height))
    if not writer.isOpened():
        writer.release()
        raise RuntimeError("Could not initialize annotated MP4 writer")
    try:
        for index, (_, _, frame_path) in enumerate(ordered):
            frame = first_frame if index == 0 else decode(frame_path)
            if frame is None:
                raise RuntimeError("Could not decode an annotated frame")
            if frame.shape[1] != width or frame.shape[0] != height:
                frame = cv2.resize(frame, (width, height))
            writer.write(frame)
    finally:
        writer.release()


def temporary_upload() -> Path:
    handle, name = tempfile.mkstemp(prefix="disc-flight-upload-")
    Path(name).chmod(0o600)
    import os
    os.close(handle)
    return Path(name)
