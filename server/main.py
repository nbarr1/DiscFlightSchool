"""
FastAPI server for disc golf training data collection and model distribution.

Run with: uvicorn main:app --host 0.0.0.0 --port 8000

Endpoints:
  POST /api/training/upload   — receive training sample (images + YOLO label)
  GET  /api/training/stats    — dataset statistics
  GET  /api/training/export   — download all training data as ZIP
  POST /api/training/start    — kick off YOLOv8 training run
  GET  /api/model/version     — current model version + hash
  GET  /api/model/download    — download latest .tflite model
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import threading
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, File, Form, Header, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse

APP_API_KEY = os.environ.get("APP_API_KEY")
if not APP_API_KEY:
    raise RuntimeError("APP_API_KEY must be set before starting the training server")

_ALLOWED_ORIGINS = [
    origin.strip()
    for origin in os.environ.get("CORS_ALLOW_ORIGINS", "").split(",")
    if origin.strip()
]
MAX_UPLOAD_BYTES = int(os.environ.get("MAX_UPLOAD_BYTES", str(8 * 1024 * 1024)))
_SAFE_SAMPLE_ID = re.compile(r"^[A-Za-z0-9_-]{1,80}$")
_YOLO_LABEL = re.compile(
    r"^0\s+"
    r"(?:0(?:\.\d+)?|1(?:\.0+)?)\s+"
    r"(?:0(?:\.\d+)?|1(?:\.0+)?)\s+"
    r"(?:0(?:\.\d+)?|1(?:\.0+)?)\s+"
    r"(?:0(?:\.\d+)?|1(?:\.0+)?)$"
)
_IMAGE_SIGNATURES = {
    ".jpg": (b"\xff\xd8\xff",),
    ".jpeg": (b"\xff\xd8\xff",),
    ".png": (b"\x89PNG\r\n\x1a\n",),
}

app = FastAPI(title="Disc Flight School Training Server")

app.add_middleware(
    CORSMiddleware,
    allow_origins=_ALLOWED_ORIGINS or [],
    allow_methods=["*"],
    allow_headers=["*"],
)


def _require_api_key(x_app_key: str | None) -> JSONResponse | None:
    """Validate API key header. Returns error response if invalid, None if OK."""
    if x_app_key != APP_API_KEY:
        return JSONResponse(
            {"error": "Invalid or missing API key"},
            status_code=403,
        )


def _validate_sample_id(sample_id: str) -> JSONResponse | None:
    if not _SAFE_SAMPLE_ID.fullmatch(sample_id):
        return JSONResponse(
            {"error": "sample_id must contain only letters, numbers, underscores, and hyphens"},
            status_code=400,
        )
    return None


def _validate_yolo_label(label: str) -> JSONResponse | None:
    lines = [line.strip() for line in label.strip().splitlines() if line.strip()]
    if len(lines) != 1 or not _YOLO_LABEL.fullmatch(lines[0]):
        return JSONResponse(
            {"error": "label must be a single YOLO class-0 row with normalized values"},
            status_code=400,
        )
    return None


def _safe_child(base: Path, filename: str) -> Path:
    base_resolved = base.resolve()
    path = (base_resolved / filename).resolve()
    if base_resolved != path.parent:
        raise ValueError("Unsafe output path")
    return path


def _normalized_image_ext(filename: str | None) -> str:
    ext = Path(filename or "image.jpg").suffix.lower()
    if ext in _IMAGE_SIGNATURES:
        return ext
    return ".jpg"


def _validate_image_signature(ext: str, header: bytes) -> bool:
    return any(header.startswith(sig) for sig in _IMAGE_SIGNATURES[ext])


def _copy_upload_image(upload: UploadFile, dest: Path, ext: str) -> int:
    total = 0
    header = b""
    with open(dest, "wb") as f:
        while True:
            chunk = upload.file.read(1024 * 1024)
            if not chunk:
                break
            if not header:
                header = chunk[:16]
            total += len(chunk)
            if total > MAX_UPLOAD_BYTES:
                f.close()
                dest.unlink(missing_ok=True)
                raise ValueError("Uploaded image exceeds size limit")
            f.write(chunk)
    if total == 0 or not _validate_image_signature(ext, header):
        dest.unlink(missing_ok=True)
        raise ValueError("Uploaded image type does not match an allowed JPEG/PNG signature")
    return total


BASE_DIR = Path(__file__).parent
DATASET_DIR = BASE_DIR / "dataset"
IMAGES_DIR = DATASET_DIR / "images" / "train"
LABELS_DIR = DATASET_DIR / "labels" / "train"
MODELS_DIR = BASE_DIR / "models"
STATS_FILE = BASE_DIR / "stats.json"
DATASET_YAML = DATASET_DIR / "dataset.yaml"

# Ensure directories exist
IMAGES_DIR.mkdir(parents=True, exist_ok=True)
LABELS_DIR.mkdir(parents=True, exist_ok=True)
MODELS_DIR.mkdir(parents=True, exist_ok=True)

# Write YOLO dataset config if it doesn't exist
if not DATASET_YAML.exists():
    DATASET_YAML.write_text(
        f"path: {DATASET_DIR.resolve()}\n"
        "train: images/train\n"
        "val: images/train\n"
        "\n"
        "names:\n"
        "  0: disc\n"
    )

# Training state
_training_lock = threading.Lock()
_training_status: dict = {"running": False, "last_run": None, "result": None}


def _load_stats() -> dict:
    if STATS_FILE.exists():
        return json.loads(STATS_FILE.read_text())
    return {"total_samples": 0, "last_upload": None}


def _save_stats(stats: dict):
    STATS_FILE.write_text(json.dumps(stats, indent=2))


def _get_model_info() -> dict | None:
    """Find the latest .tflite model and compute its metadata."""
    tflite_files = list(MODELS_DIR.glob("*.tflite"))
    if not tflite_files:
        return None
    # Use the most recently modified model file
    model_path = max(tflite_files, key=lambda p: p.stat().st_mtime)
    sha256 = hashlib.sha256(model_path.read_bytes()).hexdigest()
    # Version from filename or modification time
    version = model_path.stem  # e.g. "disc_detector_v2" -> version string
    return {"path": model_path, "version": version, "sha256": sha256}


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@app.post("/api/training/upload")
async def upload_training_sample(
    sample_id: str = Form(...),
    label: str = Form(...),
    image_width: int = Form(...),
    image_height: int = Form(...),
    app_version: str = Form("unknown"),
    full_image: UploadFile = File(...),
    crop_image: UploadFile = File(...),
    x_app_key: str | None = Header(None),
):
    """
    Receive a training sample from the app.
    Stores the full image in YOLO images/train/ and the label in labels/train/.
    Crop image is saved alongside for review.
    """
    auth_error = _require_api_key(x_app_key)
    if auth_error:
        return auth_error

    sample_error = _validate_sample_id(sample_id)
    if sample_error:
        return sample_error
    label_error = _validate_yolo_label(label)
    if label_error:
        return label_error
    if image_width <= 0 or image_height <= 0:
        return JSONResponse({"error": "image dimensions must be positive"}, status_code=400)

    full_ext = _normalized_image_ext(full_image.filename)
    crop_ext = _normalized_image_ext(crop_image.filename)
    full_dest = _safe_child(IMAGES_DIR, f"{sample_id}_full{full_ext}")
    crop_dest = _safe_child(IMAGES_DIR, f"{sample_id}_crop{crop_ext}")
    label_dest = _safe_child(LABELS_DIR, f"{sample_id}.txt")

    try:
        _copy_upload_image(full_image, full_dest, full_ext)
        _copy_upload_image(crop_image, crop_dest, crop_ext)
    except ValueError as exc:
        return JSONResponse({"error": str(exc)}, status_code=400)

    label_dest.write_text(label.strip())

    # Update stats
    stats = _load_stats()
    stats["total_samples"] = stats.get("total_samples", 0) + 1
    stats["last_upload"] = datetime.now().isoformat()
    _save_stats(stats)

    return JSONResponse(
        {"status": "ok", "sample_id": sample_id, "message": "Sample received"}
    )


@app.get("/api/model/version")
async def get_model_version():
    """Return the current model version and SHA-256 hash."""
    info = _get_model_info()
    if info is None:
        return JSONResponse(
            {"version": "none", "sha256": "", "url": ""},
            status_code=200,
        )
    return {
        "version": info["version"],
        "sha256": info["sha256"],
        "url": "/api/model/download",
    }


@app.get("/api/model/download")
async def download_model():
    """Serve the latest .tflite model file."""
    info = _get_model_info()
    if info is None:
        return JSONResponse({"error": "No model available"}, status_code=404)
    return FileResponse(
        info["path"],
        media_type="application/octet-stream",
        filename=info["path"].name,
    )


@app.get("/api/training/stats")
async def get_training_stats():
    """Return training data statistics."""
    stats = _load_stats()
    # Count actual files on disk
    image_count = len(list(IMAGES_DIR.glob("*_full.*")))  # only full images
    label_count = len(list(LABELS_DIR.glob("*.txt")))
    return {
        "total_samples": stats.get("total_samples", 0),
        "images_on_disk": image_count,
        "labels_on_disk": label_count,
        "last_upload": stats.get("last_upload"),
    }


@app.get("/api/training/export")
async def export_training_data(x_app_key: str | None = Header(None)):
    """Download all training images and labels as a ZIP file."""
    auth_error = _require_api_key(x_app_key)
    if auth_error:
        return auth_error
    image_count = len(list(IMAGES_DIR.glob("*.*")))
    label_count = len(list(LABELS_DIR.glob("*.txt")))
    if image_count == 0 and label_count == 0:
        return JSONResponse({"error": "No training data to export"}, status_code=404)

    zip_path = BASE_DIR / "training_export.zip"
    shutil.make_archive(str(zip_path.with_suffix("")), "zip", str(DATASET_DIR))
    return FileResponse(
        zip_path,
        media_type="application/zip",
        filename=f"disc_training_{datetime.now().strftime('%Y%m%d_%H%M%S')}.zip",
    )


def _run_training():
    """Background thread: run YOLOv8 training and convert to TFLite."""
    global _training_status
    try:
        _training_status["result"] = "training"

        # Train YOLOv8 nano model
        result = subprocess.run(
            [
                "yolo", "detect", "train",
                f"data={DATASET_YAML.resolve()}",
                "model=yolov8n.pt",
                "epochs=50",
                "imgsz=640",
                "batch=16",
                f"project={BASE_DIR / 'runs'}",
                "name=disc_detector",
                "exist_ok=True",
            ],
            capture_output=True,
            text=True,
            timeout=7200,  # 2 hour max
        )

        if result.returncode != 0:
            _training_status["result"] = f"failed: {result.stderr[-500:]}"
            return

        # Export best model to TFLite
        best_pt = BASE_DIR / "runs" / "disc_detector" / "weights" / "best.pt"
        if best_pt.exists():
            export_result = subprocess.run(
                ["yolo", "export", f"model={best_pt}", "format=tflite", "imgsz=640"],
                capture_output=True,
                text=True,
                timeout=600,
            )
            if export_result.returncode != 0:
                _training_status["result"] = f"failed export: {export_result.stderr[-500:]}"
                return

            # YOLOv8 exports to best_float32.tflite or similar
            for tflite in best_pt.parent.glob("*.tflite"):
                version = f"disc_detector_v{datetime.now().strftime('%Y%m%d%H%M')}"
                dest = MODELS_DIR / f"{version}.tflite"
                shutil.copy2(tflite, dest)
                _training_status["result"] = f"success: {version}"
                return

        _training_status["result"] = "failed: no TFLite model produced"

    except subprocess.TimeoutExpired:
        _training_status["result"] = "failed: training timed out"
    except Exception as e:
        _training_status["result"] = f"failed: {e}"
    finally:
        with _training_lock:
            _training_status["running"] = False
            _training_status["last_run"] = datetime.now().isoformat()


@app.post("/api/training/start")
async def start_training(x_app_key: str | None = Header(None)):
    """Kick off a YOLOv8 training run in the background.
    Requires ultralytics to be installed: pip install ultralytics
    """
    auth_error = _require_api_key(x_app_key)
    if auth_error:
        return auth_error
    with _training_lock:
        if _training_status["running"]:
            return JSONResponse(
                {"status": "already_running", "message": "Training is already in progress"},
                status_code=409,
            )
        _training_status["running"] = True

    # Check we have enough data
    image_count = len(list(IMAGES_DIR.glob("*_full.*")))
    if image_count < 10:
        with _training_lock:
            _training_status["running"] = False
        return JSONResponse(
            {"status": "insufficient_data", "count": image_count, "minimum": 10},
            status_code=400,
        )

    thread = threading.Thread(target=_run_training, daemon=True)
    thread.start()

    return {"status": "started", "message": f"Training started with {image_count} samples"}


@app.get("/api/training/status")
async def get_training_status():
    """Check the status of an ongoing training run."""
    return _training_status


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/")
async def root():
    return {
        "service": "Disc Flight School Training Server",
        "endpoints": [
            "POST /api/training/upload",
            "GET  /api/training/stats",
            "GET  /api/training/export",
            "POST /api/training/start",
            "GET  /api/training/status",
            "GET  /api/model/version",
            "GET  /api/model/download",
            "GET  /health",
        ],
    }
