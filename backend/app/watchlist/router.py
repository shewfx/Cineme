import uuid
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header, Query
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session

from app.core import idempotency
from app.core.auth import Identity, current_identity
from app.core.db import get_session
from app.core.features import series_enabled
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
    sort: service.WatchlistSort = service.DEFAULT_SORT,
    media: Annotated[Literal["all", "movies", "shows"] | None, Query()] = None,
) -> WatchlistPage:
    """`media` filters what is listed (default all) for clients that declared
    series support; others always get movies. Filtering never changes data."""
    effective = (media or "all") if series_enabled() else "movies"
    return service.list_entries(
        session, provider, identity.user_id, limit, cursor, q, sort, effective
    )


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
    status, payload = service.add(
        session, provider, identity.user_id, body.tmdb_id, key, body.media_type
    )
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
