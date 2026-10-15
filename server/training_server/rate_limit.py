"""In-memory request limits for the endpoints that spend Roboflow credits.

The server runs one worker (see the Dockerfile), so process-local counters
see every request. They reset on restart, which is acceptable for a spending
guard: a restart doesn't hand anyone more than one more window's worth.
"""

from __future__ import annotations

import threading
import time
from collections import deque
from typing import Callable

from starlette.requests import Request


class SlidingWindowLimiter:
    """Allows at most `limit` events per key in any `window_seconds`."""

    def __init__(
        self,
        limit: int,
        window_seconds: float,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.limit = limit
        self.window_seconds = window_seconds
        self._clock = clock
        self._events: dict[str, deque[float]] = {}
        self._lock = threading.Lock()

    def acquire(self, key: str) -> float | None:
        """Record one event for `key`, or return the seconds to wait if full."""
        now = self._clock()
        cutoff = now - self.window_seconds
        with self._lock:
            events = self._events.setdefault(key, deque())
            while events and events[0] <= cutoff:
                events.popleft()
            if len(events) >= self.limit:
                return max(1.0, events[0] - cutoff)
            events.append(now)
            # Forget idle keys so one-off callers don't accumulate forever.
            if len(self._events) > 10_000:
                for stale in [k for k, v in self._events.items() if not v or v[-1] <= cutoff]:
                    del self._events[stale]
            return None

    def release(self, key: str) -> None:
        """Undo the newest event for `key`, for a request that was refused later."""
        with self._lock:
            events = self._events.get(key)
            if events:
                events.pop()


def client_ip(request: Request, trusted_proxy_hops: int) -> str:
    """The caller's address, trusting only the proxies the operator declared."""
    if trusted_proxy_hops > 0:
        forwarded = [
            part.strip()
            for part in request.headers.get("x-forwarded-for", "").split(",")
            if part.strip()
        ]
        if len(forwarded) >= trusted_proxy_hops:
            return forwarded[-trusted_proxy_hops]
    return request.client.host if request.client else "unknown"
