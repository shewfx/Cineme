"""Client capability gating (ADR 011).

A client that can render shows and episodes sends `X-Cineme-Features:
series-v1`. Without it the server keeps the movie-only contract exactly as it
was: no series in watchlists, blocks or search, no episode picks in Today, and
the stored media preference is ignored for that client. The flag lives in a
context variable set by a small ASGI middleware, so every code path that builds
a Today envelope sees the same answer without threading a parameter through.
"""

from contextvars import ContextVar

from starlette.types import ASGIApp, Receive, Scope, Send

FEATURE_HEADER = b"x-cineme-features"
SERIES_FEATURE = "series-v1"

_series: ContextVar[bool] = ContextVar("cineme_series_v1", default=False)


def series_enabled() -> bool:
    """True when the current request declared series support."""
    return _series.get()


class FeatureMiddleware:
    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        declared: set[str] = set()
        for name, value in scope.get("headers", []):
            if name == FEATURE_HEADER:
                declared = {v.strip() for v in value.decode("latin-1").split(",")}
        token = _series.set(SERIES_FEATURE in declared)
        try:
            await self.app(scope, receive, send)
        finally:
            _series.reset(token)
