"""FastAPI app factory for the rebuilt training server."""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import time
import uuid
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, File, Form, Header, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from starlette.background import BackgroundTask

from .config import Settings
from .disc_flight import ALLOWED_VIDEO_TYPES, DiscFlightJobManager, temporary_upload
from .protocols import StorageBackend
from .storage import FileStorage
from .training import TrainingManager
from .validation import sample_id_error, yolo_label_error

logger = logging.getLogger("disc_flight_school.training_server")


def _build_default_storage_and_trainer(
    settings: Settings, storage: StorageBackend | None
) -> tuple[StorageBackend, TrainingManager]:
    if storage is not None:
        return storage, TrainingManager(settings, storage)

    if settings.database_url and settings.object_storage_endpoint and settings.redis_url:
        from psycopg_pool import ConnectionPool
        from redis import Redis

        from .durable_storage import PostgresMinioStorage
        from .queue import TrainingJobQueue, TrainingRunStore

        pool = ConnectionPool(
            settings.database_url, kwargs={"autocommit": True}, min_size=1, max_size=5, open=True
        )
        durable_storage = PostgresMinioStorage(settings, pool=pool)
        job_queue = TrainingJobQueue(Redis.from_url(settings.redis_url))
        run_store = TrainingRunStore(pool)
        trainer = TrainingManager(
            settings, durable_storage, job_queue=job_queue, run_store=run_store
        )
        return durable_storage, trainer

    file_storage = FileStorage(settings)
    return file_storage, TrainingManager(settings, file_storage)


def create_app(
    settings: Settings,
    storage: StorageBackend | None = None,
    disc_flight_manager: DiscFlightJobManager | None = None,
) -> FastAPI:
    """Build the FastAPI app with explicit dependencies."""
    storage, trainer = _build_default_storage_and_trainer(settings, storage)
    storage.initialize()

    app = FastAPI(title="Disc Flight School Training Server")
    app.state.settings = settings
    app.state.storage = storage
    app.state.trainer = trainer
    flight_jobs = disc_flight_manager or DiscFlightJobManager(settings)
    app.state.disc_flight_jobs = flight_jobs

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
        # compare_digest keeps the comparison constant-time with respect to the
        # secret, so a caller cannot recover the key byte-by-byte from response
        # timing. It requires str/bytes, hence the None guard.
        if x_app_key is None or not hmac.compare_digest(
            x_app_key, settings.app_api_key
        ):
            return JSONResponse({"error": "Invalid or missing API key"}, status_code=403)
        return None

    def owned_job(job_id: str, token: str | None):
        job = flight_jobs.get(job_id, token)
        if job is None:
            return JSONResponse({"error": "Job not found"}, status_code=404)
        return job

    @app.post("/api/disc-flight/jobs", status_code=202)
    async def create_disc_flight_job(
        video: UploadFile | None = File(None),
        x_app_key: str | None = Header(None),
    ):
        if auth_error := require_api_key(x_app_key):
            return auth_error
        if video is None:
            return JSONResponse({"error": "A video file is required"}, status_code=400)
        content_type = (video.content_type or "").split(";", 1)[0].lower()
        suffix = Path(video.filename or "").suffix.lower()
        expected_suffix = ALLOWED_VIDEO_TYPES.get(content_type)
        allowed_suffixes = set(ALLOWED_VIDEO_TYPES.values())
        if expected_suffix is None or suffix not in allowed_suffixes:
            return JSONResponse(
                {"error": "Unsupported video format. Use MP4, MOV, WebM, or MKV."},
                status_code=415,
            )
        temporary = temporary_upload()
        size = 0
        digest = hashlib.sha256()
        try:
            with temporary.open("wb") as destination:
                while chunk := await video.read(1024 * 1024):
                    size += len(chunk)
                    if size > settings.disc_flight_max_upload_bytes:
                        return JSONResponse(
                            {"error": "Video exceeds the configured upload limit"},
                            status_code=413,
                        )
                    digest.update(chunk)
                    destination.write(chunk)
            if size == 0:
                return JSONResponse({"error": "The uploaded video is empty"}, status_code=400)
            if not settings.roboflow_api_key:
                return JSONResponse(
                    {"error": "Roboflow processing is not configured on this server"},
                    status_code=503,
                )
            try:
                job, token = flight_jobs.create(temporary, suffix, digest.hexdigest())
            except ValueError as exc:
                return JSONResponse({"error": str(exc)}, status_code=409)
            return {"jobId": job.id, "status": "queued", "jobToken": token}
        finally:
            temporary.unlink(missing_ok=True)
            await video.close()

    @app.get("/api/disc-flight/jobs/{job_id}")
    async def get_disc_flight_job(
        job_id: str,
        x_app_key: str | None = Header(None),
        x_job_token: str | None = Header(None),
    ):
        if auth_error := require_api_key(x_app_key):
            return auth_error
        job = owned_job(job_id, x_job_token)
        return job if isinstance(job, JSONResponse) else job.public()

    @app.get("/api/disc-flight/jobs/{job_id}/result")
    async def get_disc_flight_result(
        job_id: str,
        x_app_key: str | None = Header(None),
        x_job_token: str | None = Header(None),
    ):
        if auth_error := require_api_key(x_app_key):
            return auth_error
        job = owned_job(job_id, x_job_token)
        if isinstance(job, JSONResponse):
            return job
        if job.status != "complete" or not job.output_path.is_file():
            return JSONResponse({"error": "Result is not ready"}, status_code=409)
        return FileResponse(job.output_path, media_type="video/mp4", filename="disc-flight.mp4")

    @app.delete("/api/disc-flight/jobs/{job_id}")
    async def cancel_disc_flight_job(
        job_id: str,
        x_app_key: str | None = Header(None),
        x_job_token: str | None = Header(None),
    ):
        if auth_error := require_api_key(x_app_key):
            return auth_error
        job = owned_job(job_id, x_job_token)
        if isinstance(job, JSONResponse):
            return job
        flight_jobs.cancel(job)
        return {"jobId": job.id, "status": job.status}

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
    def get_model_version():
        info = storage.latest_model_info()
        if info is None:
            return JSONResponse({"version": "none", "sha256": "", "url": ""}, status_code=200)
        return {"version": info["version"], "sha256": info["sha256"], "url": "/api/model/download"}

    @app.get("/api/model/download")
    async def download_model():
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
        stats = storage.load_stats()
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
                "POST /api/disc-flight/jobs",
                "GET  /api/disc-flight/jobs/{jobId}",
                "DELETE /api/disc-flight/jobs/{jobId}",
                "GET  /health",
            ],
        }

    return app
