import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Header, Query
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session

from app.core import idempotency
from app.core.auth import Identity, current_identity
from app.core.db import get_session
from app.movies.router import Provider

from . import service
from .schemas import AddRequest, AddResponse, RemoveResponse, WatchlistPage

router = APIRouter(prefix="/api/v1/watchlist", tags=["watchlist"])

CallerIdentity = Annotated[Identity, Depends(current_identity)]
DbSession = Annotated[Session, Depends(get_session)]
IdempotencyKey = Annotated[str | None, Header(alias="Idempotency-Key")]


@router.get("", response_model=WatchlistPage)
def list_watchlist(
    identity: CallerIdentity,
    session: DbSession,
    provider: Provider,
    limit: Annotated[int, Query(ge=1, le=50)] = 20,
    cursor: Annotated[str | None, Query(max_length=200)] = None,
    q: Annotated[str | None, Query(min_length=1, max_length=100)] = None,
) -> WatchlistPage:
    return service.list_entries(session, provider, identity.user_id, limit, cursor, q)


@router.post(
    "",
    response_model=AddResponse,
    status_code=201,
    responses={200: {"model": AddResponse, "description": "Already in the watchlist"}},
)
def add_to_watchlist(
    body: AddRequest,
    identity: CallerIdentity,
    session: DbSession,
    provider: Provider,
    idempotency_key: IdempotencyKey = None,
) -> JSONResponse:
    key = idempotency.parse_key(idempotency_key)
    status, payload = service.add(session, provider, identity.user_id, body.tmdb_id, key)
    return JSONResponse(payload, status_code=status)


@router.delete("/{entry_id}", response_model=RemoveResponse)
def remove_from_watchlist(
    entry_id: uuid.UUID,
    identity: CallerIdentity,
    session: DbSession,
    idempotency_key: IdempotencyKey = None,
) -> JSONResponse:
    key = idempotency.parse_key(idempotency_key)
    status, payload = service.remove(session, identity.user_id, entry_id, key)
    return JSONResponse(payload, status_code=status)
