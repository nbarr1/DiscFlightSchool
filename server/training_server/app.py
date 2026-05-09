"""FastAPI app factory for the rebuilt training server."""

from __future__ import annotations

import json
import logging
import time
import uuid
from datetime import datetime

from fastapi import FastAPI, File, Form, Header, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from starlette.background import BackgroundTask

from .config import Settings
from .protocols import StorageBackend
from .storage import FileStorage
from .training import TrainingManager
from .validation import sample_id_error, yolo_label_error

logger = logging.getLogger("disc_flight_school.training_server")


def create_app(settings: Settings, storage: StorageBackend | None = None) -> FastAPI:
    """Build the FastAPI app with explicit dependencies."""
    storage = storage or FileStorage(settings)
    storage.initialize()
    trainer = TrainingManager(settings, storage)

    app = FastAPI(title="Disc Flight School Training Server")
    app.state.settings = settings
    app.state.storage = storage
    app.state.trainer = trainer

    app.add_middleware(
        CORSMiddleware,
        allow_origins=list(settings.cors_allow_origins),
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @app.middleware("http")
    async def request_context_middleware(request: Request, call_next):
        request_id = request.headers.get("x-request-id") or str(uuid.uuid4())
        request.state.request_id = request_id
        start = time.perf_counter()
        logger.info(
            json.dumps(
                {
                    "event": "request.start",
                    "request_id": request_id,
                    "method": request.method,
                    "path": request.url.path,
                }
            )
        )
        response = await call_next(request)
        duration_ms = round((time.perf_counter() - start) * 1000, 3)
        response.headers["X-Request-ID"] = request_id
        logger.info(
            json.dumps(
                {
                    "event": "request.finish",
                    "request_id": request_id,
                    "method": request.method,
                    "path": request.url.path,
                    "status_code": response.status_code,
                    "duration_ms": duration_ms,
                }
            )
        )
        return response

    def require_api_key(x_app_key: str | None) -> JSONResponse | None:
        if x_app_key != settings.app_api_key:
            return JSONResponse({"error": "Invalid or missing API key"}, status_code=403)
        return None

    @app.post("/api/training/upload")
    def upload_training_sample(
        sample_id: str = Form(...),
        label: str = Form(...),
        image_width: int = Form(...),
        image_height: int = Form(...),
        app_version: str = Form("unknown"),
        full_image: UploadFile = File(...),
        crop_image: UploadFile = File(...),
        x_app_key: str | None = Header(None),
    ):
        auth_error = require_api_key(x_app_key)
        if auth_error:
            return auth_error

        if error := sample_id_error(sample_id):
            return JSONResponse({"error": error}, status_code=400)
        if error := yolo_label_error(label):
            return JSONResponse({"error": error}, status_code=400)
        if image_width <= 0 or image_height <= 0:
            return JSONResponse({"error": "image dimensions must be positive"}, status_code=400)

        try:
            storage.store_training_sample(
                sample_id=sample_id,
                label=label,
                full_image=full_image,
                crop_image=crop_image,
            )
        except ValueError as exc:
            return JSONResponse({"error": str(exc)}, status_code=400)

        return JSONResponse({"status": "ok", "sample_id": sample_id, "message": "Sample received"})

    @app.get("/api/model/version")
    async def get_model_version():
    def get_model_version():
        if info is None:
            return JSONResponse({"version": "none", "sha256": "", "url": ""}, status_code=200)
        return {"version": info["version"], "sha256": info["sha256"], "url": "/api/model/download"}

    @app.get("/api/model/download")
    def download_model():
        info = storage.latest_model_info()
        if info is None:
            return JSONResponse({"error": "No model available"}, status_code=404)
        return FileResponse(
            info["path"],
            media_type="application/octet-stream",
            filename=info["path"].name,
        )

    @app.get("/api/training/stats")
    async def get_training_stats():
    def get_training_stats():
        counts = storage.dataset_counts()
        return {
            "total_samples": stats.get("total_samples", 0),
            "images_on_disk": counts["full_images"],
            "labels_on_disk": counts["labels"],
            "last_upload": stats.get("last_upload"),
        }

    @app.get("/api/training/export")
    def export_training_data(x_app_key: str | None = Header(None)):
        auth_error = require_api_key(x_app_key)
        if auth_error:
            return auth_error
        counts = storage.dataset_counts()
        if counts["all_images"] == 0 and counts["labels"] == 0:
            return JSONResponse({"error": "No training data to export"}, status_code=404)

        zip_path = storage.build_training_export()
        return FileResponse(
            zip_path,
            media_type="application/zip",
            filename=f"disc_training_{datetime.now().strftime('%Y%m%d_%H%M%S')}.zip",
            background=BackgroundTask(zip_path.unlink, missing_ok=True),
        )

    @app.post("/api/training/start")
    async def start_training(x_app_key: str | None = Header(None)):
        auth_error = require_api_key(x_app_key)
        if auth_error:
            return auth_error
        payload, status_code = trainer.start()
        if status_code != 200:
            return JSONResponse(payload, status_code=status_code)
        return payload

    @app.get("/api/training/status")
    async def get_training_status():
        return trainer.status

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

    return app
