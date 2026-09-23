"""Single-image disc detection through the published Roboflow Workflow.

The Workflow wraps the `disc-golf-flight-tracker-2-rfdetr-small-t1` RF-DETR
model. Its published definition declares one input, the image, and no runtime
parameters, so none are sent; it returns one JSON output, `predictions`. It
returns no image-shaped outputs, so there is nothing base64-encoded to decode.

Video still goes through `disc_flight.py`'s WebRTC session. This module is for
one still image at a time.

As in `disc_flight.py`, the inference-sdk import is lazy: normal server tests
inject a fake client and never spend inference credits.
"""

from __future__ import annotations

import base64
import json
import logging
import math
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping

logger = logging.getLogger("disc_flight_school.disc_detection")

SERVERLESS_API_URL = "https://serverless.roboflow.com"
WORKSPACE = "disc-golf-tracer"
WORKFLOW = "disc-golf-flight-tracker-vdisc-golf-flight-tracker-2-rfdetr-small-t1-logic"
IMAGE_INPUT = "image"
PREDICTIONS_OUTPUT = "predictions"

DEFAULT_TIMEOUT_SECONDS = 30.0
DEFAULT_RETRIES = 2
RETRY_BACKOFF_SECONDS = 0.5
RETRYABLE_STATUS_CODES = frozenset({429, 500, 502, 503, 504})


class DiscDetectionError(Exception):
    """Base class for every failure raised by `detect_discs`."""


class DiscDetectionNotConfigured(DiscDetectionError):
    """No Roboflow API key was supplied."""


class DiscDetectionInputError(DiscDetectionError, ValueError):
    """The image could not be sent as given. Retrying cannot help."""


class DiscDetectionRequestError(DiscDetectionError):
    """The Workflow call failed after every permitted attempt."""

    def __init__(self, message: str, *, status_code: int | None = None, retryable: bool = False):
        super().__init__(message)
        self.status_code = status_code
        self.retryable = retryable


class DiscDetectionTimeout(DiscDetectionRequestError, TimeoutError):
    """An attempt did not finish within the timeout."""

    def __init__(self, message: str):
        super().__init__(message, retryable=True)


class DiscDetectionResponseError(DiscDetectionError):
    """The Workflow answered, but not in the shape its definition promises."""


@dataclass(frozen=True)
class DiscBox:
    """One detection, in pixels of the submitted image. `x`/`y` is the box center."""

    x: float
    y: float
    width: float
    height: float
    confidence: float
    class_name: str


@dataclass(frozen=True)
class DiscDetections:
    image_width: int
    image_height: int
    detections: tuple[DiscBox, ...]


def detect_discs(
    image: bytes | str | Path,
    *,
    api_key: str | None,
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
    retries: int = DEFAULT_RETRIES,
    api_url: str = SERVERLESS_API_URL,
) -> DiscDetections:
    """Run one image through the Workflow and return the discs it found.

    `image` is encoded JPEG/PNG bytes, a local file path, or an `https://` URL.
    The SDK downloads a URL on this machine before uploading it, so never pass
    a URL a client supplied without validating it first.
    """
    return parse_disc_detections(
        run_disc_detection_workflow(
            image,
            api_key=api_key,
            timeout_seconds=timeout_seconds,
            retries=retries,
            api_url=api_url,
        )
    )


def run_disc_detection_workflow(
    image: bytes | str | Path,
    *,
    api_key: str | None,
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
    retries: int = DEFAULT_RETRIES,
    api_url: str = SERVERLESS_API_URL,
) -> dict[str, Any]:
    """Return the Workflow's outputs for one image, keyed by output name.

    Each attempt is bounded by `timeout_seconds`. Connection failures,
    timeouts, and 429/5xx responses are retried up to `retries` more times
    with exponential backoff; anything else fails at once.
    """
    if not api_key:
        raise DiscDetectionNotConfigured("ROBOFLOW_API_KEY is not set on this server")
    reference = _image_reference(image)
    client = _build_client(api_key, api_url)

    def call() -> Any:
        return client.run_workflow(
            workspace_name=WORKSPACE,
            workflow_id=WORKFLOW,
            images={IMAGE_INPUT: reference},
        )

    attempts = max(0, retries) + 1
    for attempt in range(attempts):
        try:
            results = _call_with_timeout(call, timeout_seconds)
            break
        except DiscDetectionError as error:
            failure = error
        except Exception as error:
            failure = _translate(error)
            failure.__cause__ = error
        if not getattr(failure, "retryable", False) or attempt == attempts - 1:
            raise failure
        logger.warning(
            json.dumps(
                {
                    "event": "disc_detection.retry",
                    "attempt": attempt + 1,
                    "error": type(failure).__name__,
                    "status_code": getattr(failure, "status_code", None),
                }
            )
        )
        time.sleep(RETRY_BACKOFF_SECONDS * 2**attempt)

    # One image in, so one entry out.
    if not isinstance(results, list) or not results or not isinstance(results[0], dict):
        raise DiscDetectionResponseError("The Workflow returned no result for the image")
    return results[0]


def parse_disc_detections(outputs: Mapping[str, Any]) -> DiscDetections:
    """Read the `predictions` output into typed boxes.

    Only the fields this server uses are kept; detection and parent IDs are
    dropped. A malformed box is skipped and counted in a warning rather than
    failing the whole image.
    """
    block = outputs.get(PREDICTIONS_OUTPUT) if isinstance(outputs, Mapping) else None
    if not isinstance(block, Mapping):
        present = sorted(outputs) if isinstance(outputs, Mapping) else type(outputs).__name__
        raise DiscDetectionResponseError(
            f"The Workflow response has no '{PREDICTIONS_OUTPUT}' object; outputs present: {present}"
        )
    image = block.get("image")
    width = _number(image.get("width")) if isinstance(image, Mapping) else None
    height = _number(image.get("height")) if isinstance(image, Mapping) else None
    raw = block.get("predictions")
    if width is None or height is None or not isinstance(raw, list):
        raise DiscDetectionResponseError(
            f"'{PREDICTIONS_OUTPUT}' is missing its image size or predictions list; "
            f"keys present: {sorted(block)}"
        )
    boxes = tuple(box for box in map(_box, raw) if box is not None)
    if len(boxes) != len(raw):
        logger.warning(
            json.dumps({"event": "disc_detection.malformed_boxes", "skipped": len(raw) - len(boxes)})
        )
    return DiscDetections(image_width=int(width), image_height=int(height), detections=boxes)


def _build_client(api_key: str, api_url: str) -> Any:
    from inference_sdk import InferenceConfiguration, InferenceHTTPClient

    # Retries are handled here instead, so that the attempt count, backoff,
    # and per-attempt timeout are all in one place.
    return InferenceHTTPClient(api_url=api_url, api_key=api_key).configure(
        InferenceConfiguration(api_key_transport="header", workflow_run_retries_enabled=False)
    )


def _image_reference(image: bytes | str | Path) -> str:
    if isinstance(image, str) and "://" in image:
        if not image.startswith("https://"):
            raise DiscDetectionInputError("Image URLs must use https://")
        return image
    if isinstance(image, (str, Path)):
        path = Path(image)
        if not path.is_file():
            raise DiscDetectionInputError(f"Image file does not exist: {path}")
        image = path.read_bytes()
    if not isinstance(image, (bytes, bytearray)) or not image:
        raise DiscDetectionInputError("Image must be non-empty bytes, a file path, or an https:// URL")
    return base64.b64encode(image).decode("ascii")


def _call_with_timeout(call: Callable[[], Any], timeout_seconds: float) -> Any:
    # inference-sdk sets no socket timeout, so the wait is bounded here. An
    # attempt that times out is abandoned on a daemon thread, which ends when
    # its connection does and never blocks server shutdown.
    outcome: dict[str, Any] = {}

    def target() -> None:
        try:
            outcome["value"] = call()
        except Exception as error:
            outcome["error"] = error

    worker = threading.Thread(target=target, name="roboflow-workflow", daemon=True)
    worker.start()
    worker.join(timeout_seconds)
    if worker.is_alive():
        raise DiscDetectionTimeout(f"The Roboflow Workflow did not answer within {timeout_seconds:g}s")
    if "error" in outcome:
        raise outcome["error"]
    return outcome.get("value")


def _translate(error: Exception) -> DiscDetectionError:
    from inference_sdk.http.errors import HTTPCallErrorError, HTTPClientError

    if isinstance(error, HTTPCallErrorError):
        status = error.status_code
        if status in (401, 403):
            message = f"Roboflow rejected the API key (HTTP {status}); check ROBOFLOW_API_KEY"
        elif status == 404:
            message = f"Roboflow could not find Workflow {WORKSPACE}/{WORKFLOW} (HTTP 404)"
        else:
            message = f"The Roboflow Workflow request failed with HTTP {status}"
        return DiscDetectionRequestError(
            message, status_code=status, retryable=status in RETRYABLE_STATUS_CODES
        )
    # The SDK raises the bare base class for connection failures; its
    # subclasses mean the request itself was invalid.
    if type(error) is HTTPClientError or isinstance(error, OSError):
        return DiscDetectionRequestError("Could not reach the Roboflow Workflow API", retryable=True)
    if isinstance(error, HTTPClientError):
        return DiscDetectionInputError(f"The Roboflow SDK rejected the request: {type(error).__name__}")
    if isinstance(error, (KeyError, ValueError)):
        return DiscDetectionResponseError("Roboflow returned a response without Workflow outputs")
    return DiscDetectionError(f"Unexpected {type(error).__name__} from the Roboflow SDK")


def _number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return None
    return float(value)


def _box(item: Any) -> DiscBox | None:
    if not isinstance(item, Mapping):
        return None
    fields = [_number(item.get(key)) for key in ("x", "y", "width", "height", "confidence")]
    class_name = item.get("class")
    if any(value is None for value in fields) or not isinstance(class_name, str):
        return None
    x, y, width, height, confidence = fields
    return DiscBox(x, y, width, height, confidence, class_name)
