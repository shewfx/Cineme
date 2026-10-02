"""API error envelope and request IDs (API_CONTRACT "Common rules")."""

import logging
import re
import uuid
from collections.abc import Awaitable, Callable
from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.responses import Response

REQUEST_ID_HEADER = "X-Request-ID"
_REQUEST_ID = re.compile(r"^[A-Za-z0-9._-]{1,64}$")

log = logging.getLogger("cineme")


class AppError(Exception):
    """A documented domain/transport error, rendered as the error envelope."""

    def __init__(
        self,
        status: int,
        code: str,
        message: str,
        *,
        details: dict[str, Any] | None = None,
        retryable: bool = False,
    ) -> None:
        super().__init__(code)
        self.status = status
        self.code = code
        self.message = message
        self.details = details or {}
        self.retryable = retryable


def _envelope(request: Request, error: AppError) -> JSONResponse:
    return JSONResponse(
        status_code=error.status,
        content={
            "error": {
                "code": error.code,
                "message": error.message,
                "details": error.details,
                "retryable": error.retryable,
            },
            "request_id": request.state.request_id,
        },
    )


_HTTP_CODES = {
    401: ("AUTH_REQUIRED", "Sign in to continue."),
    404: ("NOT_FOUND", "Not found."),
    405: ("METHOD_NOT_ALLOWED", "Method not allowed."),
}


def install_error_handling(app: FastAPI) -> None:
    @app.middleware("http")
    async def request_id(
        request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        # A valid client ID is kept; anything else is replaced, never echoed.
        supplied = request.headers.get(REQUEST_ID_HEADER, "")
        rid = supplied if _REQUEST_ID.fullmatch(supplied) else uuid.uuid4().hex
        request.state.request_id = rid
        try:
            response = await call_next(request)
        except Exception:
            # Logged with the request ID; no stack trace or body reaches the
            # client, and the response still carries the request ID.
            log.exception("unhandled error request_id=%s", rid)
            response = _envelope(
                request,
                AppError(500, "INTERNAL_ERROR", "Something went wrong.", retryable=True),
            )
        response.headers[REQUEST_ID_HEADER] = rid
        return response

    @app.exception_handler(AppError)
    async def app_error(request: Request, exc: AppError) -> JSONResponse:
        return _envelope(request, exc)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request: Request, exc: RequestValidationError) -> JSONResponse:
        # Field locations only; never echo submitted values.
        fields = [".".join(str(p) for p in e["loc"] if p != "body") for e in exc.errors()]
        return _envelope(
            request,
            AppError(
                422,
                "VALIDATION_ERROR",
                "Some fields are invalid.",
                details={"fields": fields},
            ),
        )

    @app.exception_handler(StarletteHTTPException)
    async def http_error(request: Request, exc: StarletteHTTPException) -> JSONResponse:
        code, message = _HTTP_CODES.get(exc.status_code, ("HTTP_ERROR", "Request failed."))
        return _envelope(request, AppError(exc.status_code, code, message))
