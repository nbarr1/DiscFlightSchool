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


class NoAnnotatedFrames(RuntimeError):
    """The session ended without any `output_image` frames to assemble.

    Its message never carries credentials or upstream text, so the job log
    records it in full.
    """


class UnreadableVideo(RuntimeError):
    """The upload could not be opened or decoded as a video.

    Raised before a Roboflow session is opened, so an HTML page saved from a
    share link, or any other non-video, never spends inference credits. Its
    message never carries credentials or upstream text.
    """


class EmptyClip(UnreadableVideo):
    """The requested start/end range holds no frames of the upload."""


class VideoProcessor(Protocol):
    def __call__(
        self,
        source: Path,
        destination: Path,
        cancel: threading.Event,
        update: Callable[[int, int | None, str], None],
        clip: tuple[int, int | None] | None = None,
    ) -> dict[str, Any]: ...


@dataclass
class DiscFlightJob:
    id: str
    owner_hash: str
    directory: Path
    input_path: Path
    output_path: Path
    source_hash: str = ""
    # (start_ms, end_ms) of the upload to process, or None for all of it.
    clip: tuple[int, int | None] | None = None
    status: str = "queued"
    frames_processed: int = 0
    total_frames: int | None = None
    summary: dict[str, Any] | None = None
    # Per-frame disc positions, served by GET .../track once complete.
    track: dict[str, Any] | None = field(default=None, repr=False)
    error: str | None = None
    # time.monotonic() when the job reached a terminal status.
    finished_at: float | None = None
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
            body["trackUrl"] = f"/api/disc-flight/jobs/{self.id}/track"
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

    def __call__(self, source, destination, cancel, update, clip=None):
        if not self.settings.roboflow_api_key:
            raise RuntimeError("Roboflow processing is not configured on this server")
        if clip is None:
            return self._process(source, destination, cancel, update)

        import cv2

        # Only the clipped range goes to Roboflow: credits are spent per
        # frame, and a phone recording is mostly footage around the throw.
        clipped = destination.with_name("clip.mp4")
        try:
            _write_clip(source, clipped, clip, cv2)
            return self._process(clipped, destination, cancel, update)
        finally:
            clipped.unlink(missing_ok=True)

    def _process(self, source, destination, cancel, update):
        import cv2
        import numpy as np
        from inference_sdk import InferenceConfiguration, InferenceHTTPClient
        from inference_sdk.webrtc import StreamConfig, VideoFileSource

        capture = cv2.VideoCapture(str(source))
        try:
            readable = capture.isOpened() and capture.read()[0]
            input_fps = capture.get(cv2.CAP_PROP_FPS) or 30.0
            reliable_total = int(capture.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
            frame_width = float(capture.get(getattr(cv2, "CAP_PROP_FRAME_WIDTH", "width")) or 0)
            frame_height = float(capture.get(getattr(cv2, "CAP_PROP_FRAME_HEIGHT", "height")) or 0)
        finally:
            capture.release()
        if not readable:
            raise UnreadableVideo("The upload is not a readable video file.")
        total = reliable_total if reliable_total > 0 else None

        # Keep only small frame metadata in memory. Annotated images can be
        # several megabytes once decoded, so retaining a video's worth of
        # NumPy arrays here would allow an otherwise valid upload to exhaust
        # the API worker's memory.
        frames: list[tuple[int, float | None, Path]] = []
        detection_frames: set[int] = set()
        # frame id -> the frame's best box, for the per-frame track.
        boxes: dict[int, dict[str, float]] = {}
        seen_frames: set[int] = set()
        frame_errors: list[str] = []
        frames_lock = threading.Lock()
        data_messages = 0

        def on_data(data: dict[str, Any], metadata: Any = None) -> None:
            # Taking a second parameter is what makes the SDK pass the frame's
            # metadata; without it frame ids could only be guessed from
            # arrival order.
            nonlocal data_messages
            if cancel.is_set():
                self.close()
                return
            try:
                with frames_lock:
                    data_messages += 1
                    default_frame_id = len(frames)
                metadata_frame_id = getattr(metadata, "frame_id", None)
                frame_id = (
                    int(metadata_frame_id)
                    if isinstance(metadata_frame_id, int)
                    else _frame_id(data, default_frame_id)
                )
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
                # The tracker's output keeps one identity through the flight,
                # so it is preferred; raw detections fill frames it skipped.
                box = _best_box(data.get("tracked_disc"), frame_width, frame_height) or _best_box(
                    data.get("disc_detections"), frame_width, frame_height
                )
                with frames_lock:
                    seen_frames.add(frame_id)
                    if box is not None:
                        boxes[frame_id] = box
                    if _prediction_count(data.get("disc_detections")) > 0:
                        detection_frames.add(frame_id)
                    completed = len(frames)
                update(completed, total, "processing")
            except Exception as exc:  # one malformed frame must not end a throw
                frame_errors.append(f"frame {_frame_id(data, len(frames))}: {type(exc).__name__}")
                logger.warning(json.dumps({"event": "disc_flight.frame_error", "error": type(exc).__name__}))

        def on_error(errors: Any, metadata: Any = None) -> None:
            # The SDK passes the list of error strings the server reported for
            # one frame, plus that frame's metadata because this handler takes
            # a second parameter.
            frame_id = getattr(metadata, "frame_id", None)
            messages = [
                _loggable_error(message, self.settings.roboflow_api_key)
                for message in (errors if isinstance(errors, list) else [errors])
            ]
            frame_errors.append(f"frame {frame_id}: {messages}")
            logger.warning(
                json.dumps({"event": "disc_flight.webrtc_frame_error", "frame_id": frame_id, "errors": messages})
            )

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
                # `output_image` has to be requested here, not in
                # stream_output. For a VideoFileSource the SDK strips every
                # stream_output name out of what `on_data` receives and queues
                # those images for `session.video()` instead, which `wait()`
                # drains and discards, so every frame would be lost.
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
            if not frames:
                # Two different failures end here, and telling them apart
                # points at either the upload or the output routing.
                if data_messages == 0:
                    raise NoAnnotatedFrames(
                        "Roboflow processed no frames. "
                        "Check that the upload is a readable video file."
                    )
                raise NoAnnotatedFrames(
                    f"Roboflow returned {data_messages} frames without an output_image. "
                    "Check that the workflow exposes an output named 'output_image' "
                    "and that StreamConfig.data_output requests it."
                )
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
            "track": _build_track(boxes, seen_frames, input_fps),
        }


TERMINAL_STATUSES = frozenset({"complete", "failed", "cancelled"})

# How long a finished job, and its annotated video, stays available. The client
# downloads the result as soon as it sees "complete", so this is generous; its
# purpose is that results stop accumulating on disk without bound.
RESULT_RETENTION_SECONDS = 24 * 60 * 60


class DiscFlightJobManager:
    def __init__(
        self,
        settings: Settings,
        processor_factory=None,
        *,
        retention_seconds: float = RESULT_RETENTION_SECONDS,
    ):
        self.settings = settings
        self.root = settings.base_dir / "disc_flight_jobs"
        self.root.mkdir(parents=True, exist_ok=True)
        self.processor_factory = processor_factory or (lambda: RoboflowVideoProcessor(settings))
        self.jobs: dict[str, DiscFlightJob] = {}
        self.lock = threading.Lock()
        self.retention_seconds = retention_seconds
        self._sweep_abandoned_directories()

    def _sweep_abandoned_directories(self) -> None:
        """Remove job folders an earlier process left behind.

        The registry lives in memory, so after a restart nothing can reach
        them. Only folders untouched for the retention period are removed, in
        case another process is still using a recent one.
        """
        cutoff = time.time() - self.retention_seconds
        for directory in self.root.iterdir():
            try:
                if directory.is_dir() and directory.stat().st_mtime < cutoff:
                    shutil.rmtree(directory, ignore_errors=True)
            except OSError:
                continue

    def _prune_expired(self) -> None:
        """Forget finished jobs older than the retention period and delete their files."""
        now = time.monotonic()
        with self.lock:
            expired = [
                job
                for job in self.jobs.values()
                if job.status in TERMINAL_STATUSES
                and job.finished_at is not None
                and now - job.finished_at > self.retention_seconds
            ]
            for job in expired:
                del self.jobs[job.id]
        for job in expired:
            shutil.rmtree(job.directory, ignore_errors=True)

    @staticmethod
    def token_hash(token: str) -> str:
        return hashlib.sha256(token.encode()).hexdigest()

    def create(
        self,
        source: Path,
        suffix: str,
        source_hash: str,
        clip: tuple[int, int | None] | None = None,
    ) -> tuple[DiscFlightJob, str]:
        self._prune_expired()
        token = secrets.token_urlsafe(32)
        job_id = str(uuid.uuid4())
        directory = self.root / job_id
        directory.mkdir(mode=0o700)
        input_path = directory / f"input{suffix}"
        shutil.move(str(source), input_path)
        job = DiscFlightJob(
            job_id,
            self.token_hash(token),
            directory,
            input_path,
            directory / "result.mp4",
            source_hash,
            clip=clip,
        )
        with self.lock:
            if any(
                existing.source_hash == source_hash and existing.status not in TERMINAL_STATUSES
                for existing in self.jobs.values()
            ):
                shutil.rmtree(directory, ignore_errors=True)
                raise ValueError("This video already has an active processing job")
            self.jobs[job_id] = job
        threading.Thread(target=self._run, args=(job,), daemon=True).start()
        return job, token

    def get(self, job_id: str, token: str | None) -> DiscFlightJob | None:
        self._prune_expired()
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
        if job.status not in TERMINAL_STATUSES:
            job.finished_at = time.monotonic()
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
            summary = processor(
                job.input_path, job.output_path, job.cancel_event, update, clip=job.clip
            )
            job.track = summary.pop("track", None)
            job.summary = summary
            if job.cancel_event.is_set():
                raise Cancelled()
            job.finished_at = time.monotonic()
            job.status = "complete"
        except Cancelled:
            job.finished_at = time.monotonic()
            job.status = "cancelled"
            job.output_path.unlink(missing_ok=True)
        except Exception as exc:
            # Record the error and log it before publishing the terminal
            # status, so a poller that sees "failed" also sees why.
            job.error = _safe_error(exc)
            job.output_path.unlink(missing_ok=True)
            event = {"event": "disc_flight.job_failed", "job_id": job.id, "error": type(exc).__name__}
            if isinstance(exc, (NoAnnotatedFrames, UnreadableVideo)):
                event["detail"] = str(exc)
            logger.error(json.dumps(event))
            job.finished_at = time.monotonic()
            job.status = "failed"
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
    if isinstance(exc, EmptyClip):
        return str(exc)
    if isinstance(exc, UnreadableVideo):
        return "The uploaded file could not be read as a video. Upload the video file itself."
    if isinstance(exc, RuntimeError) and "not configured" in str(exc):
        return str(exc)
    return "The disc-flight service could not process this video. Please retry."


def _loggable_error(message: Any, api_key: str | None) -> str:
    """A server-reported frame error with the Roboflow key removed and its length capped.

    The server builds these from arbitrary exception text, which can include a
    request URL carrying the key.
    """
    text = str(message)
    if api_key:
        text = text.replace(api_key, "[redacted]")
    return text[:500]


def _output_value(value: Any) -> str | None:
    if isinstance(value, str):
        return value
    if isinstance(value, dict) and isinstance(value.get("value"), str):
        return value["value"]
    return None


def _best_box(value: Any, frame_width: float, frame_height: float) -> dict[str, float] | None:
    """The highest-confidence box in one Workflow detections output, normalized
    to 0-1 of the frame, or None when it holds no usable box.

    Workflow detections serialize as `{"image": {"width", "height"},
    "predictions": [{"x", "y", "width", "height", "confidence", ...}]}`, with
    `x`/`y` the box center in pixels, sometimes wrapped as `{"value": ...}`.
    """
    value = value.get("value", value) if isinstance(value, dict) and "predictions" not in value else value
    image: Any = None
    if isinstance(value, dict):
        image = value.get("image")
        value = value.get("predictions")
    if not isinstance(value, list):
        return None
    width = _positive(image.get("width")) if isinstance(image, dict) else None
    height = _positive(image.get("height")) if isinstance(image, dict) else None
    width = width or _positive(frame_width)
    height = height or _positive(frame_height)
    if width is None or height is None:
        return None

    best: dict[str, float] | None = None
    for prediction in value:
        if not isinstance(prediction, dict):
            continue
        fields = [_finite(prediction.get(key)) for key in ("x", "y", "width", "height", "confidence")]
        if any(field is None for field in fields):
            continue
        x, y, box_width, box_height, confidence = fields
        if best is None or confidence > best["confidence"]:
            best = {
                "x": min(1.0, max(0.0, x / width)),
                "y": min(1.0, max(0.0, y / height)),
                "width": min(1.0, max(0.0, box_width / width)),
                "height": min(1.0, max(0.0, box_height / height)),
                "confidence": confidence,
            }
    return best


def _build_track(
    boxes: dict[int, dict[str, float]], seen_frames: set[int], fps: float
) -> dict[str, Any]:
    """Per-frame disc positions, with frame 0 as the first frame processed.

    SDK frame ids may start at 0 or 1; counting from the first one seen keeps
    frame 0 at the start of the (clipped) upload either way.
    """
    first = min(seen_frames) if seen_frames else 0
    detections = []
    for frame_id in sorted(boxes):
        frame = frame_id - first
        detections.append(
            {
                "frame": frame,
                "timeMs": round(frame * 1000.0 / fps),
                **{key: round(value, 5) for key, value in boxes[frame_id].items()},
            }
        )
    return {"fps": fps, "frameCount": len(seen_frames), "detections": detections}


def _finite(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    return number if number == number and abs(number) != float("inf") else None


def _positive(value: Any) -> float | None:
    number = _finite(value)
    return number if number is not None and number > 0 else None


def _write_clip(source: Path, destination: Path, clip: tuple[int, int | None], cv2: Any) -> None:
    """Copy the `clip` range of `source`, in milliseconds, into a new MP4.

    Frames are counted from the source's frame rate rather than read back from
    the decoder's position, which some containers report only approximately.
    """
    start_ms, end_ms = clip
    capture = cv2.VideoCapture(str(source))
    writer = None
    written = 0
    try:
        if not capture.isOpened():
            raise UnreadableVideo("The upload is not a readable video file.")
        fps = capture.get(cv2.CAP_PROP_FPS) or 30.0
        start_frame = round(start_ms * fps / 1000.0)
        last_frame = None if end_ms is None else round(end_ms * fps / 1000.0)
        capture.set(cv2.CAP_PROP_POS_FRAMES, start_frame)
        frame_index = start_frame
        while last_frame is None or frame_index <= last_frame:
            ok, frame = capture.read()
            if not ok:
                break
            if writer is None:
                height, width = frame.shape[:2]
                writer = cv2.VideoWriter(str(destination), cv2.VideoWriter_fourcc(*"mp4v"), fps, (width, height))
                if not writer.isOpened():
                    raise RuntimeError("Could not initialize the clip writer")
            writer.write(frame)
            written += 1
            frame_index += 1
    finally:
        capture.release()
        if writer is not None:
            writer.release()
    if written == 0:
        raise EmptyClip("The selected part of the video has no frames. Choose a longer range.")


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
        raise NoAnnotatedFrames("No annotated frames to write")
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
