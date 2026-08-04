"""
FastAPI entrypoint for Disc Flight School training data collection and model distribution.

Run with: uvicorn main:app --host 0.0.0.0 --port 8000
       or: gunicorn main:app -w 2 -k uvicorn.workers.UvicornWorker

This module is deliberately thin — all behaviour lives in the `training_server`
package so it can be imported and tested without starting a server.
"""

from __future__ import annotations

from pathlib import Path

from training_server import Settings, create_app

settings = Settings.from_env(base_dir=Path(__file__).parent)
app = create_app(settings)
