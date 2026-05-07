"""Disc Flight School training server package."""

from .app import create_app
from .config import Settings

__all__ = ["Settings", "create_app"]
