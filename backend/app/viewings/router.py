import uuid
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Header, Query
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session

from app.core import idempotency
from app.core.auth import Identity, current_identity
from app.core.db import get_session
from app.movies.router import Provider

from . import service
from .schemas import RatingPatch, RecordViewing, ViewingPage

router = APIRouter(prefix="/api/v1", tags=["history"])
CallerIdentity = Annotated[Identity, Depends(current_identity)]
DbSession = Annotated[Session, Depends(get_session)]
IdempotencyKey = Annotated[str | None, Header(alias="Idempotency-Key")]


@router.get("/viewings", response_model=ViewingPage)
def list_viewings(
    identity: CallerIdentity,
    session: DbSession,
    provider: Provider,
    limit: Annotated[int, Query(ge=1, le=50)] = 20,
    cursor: Annotated[str | None, Query(max_length=64)] = None,
) -> dict[str, Any]:
    return service.list_page(session, provider, identity.user_id, limit, cursor)


@router.post("/viewings", response_model=None)
def create_viewing(
    body: RecordViewing,
    identity: CallerIdentity,
    session: DbSession,
    provider: Provider,
    idempotency_key: IdempotencyKey = None,
) -> JSONResponse:
    key = idempotency.parse_key(idempotency_key)
    status, payload = service.record(session, provider, identity.user_id, body, key)
    return JSONResponse(payload, status_code=status)


@router.patch("/viewings/{viewing_id}", response_model=None)
def patch_viewing(
    viewing_id: uuid.UUID,
    body: RatingPatch,
    identity: CallerIdentity,
    session: DbSession,
    provider: Provider,
    idempotency_key: IdempotencyKey = None,
) -> JSONResponse:
    key = idempotency.parse_key(idempotency_key)
    status, payload = service.update_rating(
        session, provider, identity.user_id, viewing_id, body, key
    )
    return JSONResponse(payload, status_code=status)
