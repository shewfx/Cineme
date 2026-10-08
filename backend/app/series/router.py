import uuid
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Header, Path, Query
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session

from app.core import idempotency
from app.core.auth import Identity, current_identity
from app.core.db import get_session
from app.movies import availability
from app.movies.router import Provider
from app.movies.schemas import AvailabilityResponse

from . import service
from .schemas import (
    EpisodeRatingRequest,
    ProgressRequest,
    SeasonsResponse,
    SeriesDetails,
    SeriesRatingRequest,
    TrendingShowsResponse,
    TvSearchResponse,
    WatchedEpisodeRequest,
)

router = APIRouter(prefix="/api/v1", tags=["series"])

CallerIdentity = Annotated[Identity, Depends(current_identity)]
DbSession = Annotated[Session, Depends(get_session)]
IdempotencyKey = Annotated[str | None, Header(alias="Idempotency-Key")]
TvId = Annotated[int, Path(gt=0, le=2_147_483_647)]


@router.get("/tv/search", response_model=TvSearchResponse)
def search_tv(
    identity: CallerIdentity,
    session: DbSession,
    provider: Provider,
    q: Annotated[str, Query(min_length=2, max_length=100)],
    page: Annotated[int, Query(ge=1, le=500)] = 1,
) -> TvSearchResponse:
    """TMDB TV search through the backend; the TMDB token never reaches Flutter."""
    return service.search(session, provider, identity.user_id, q.strip(), page)


@router.get("/tv/trending", response_model=TrendingShowsResponse)
def trending_shows(
    identity: CallerIdentity, session: DbSession, provider: Provider
) -> TrendingShowsResponse:
    """This week's trending shows for discovery. Not personalized and not a
    recommendation; at most 12. Registered before `/tv/{tmdb_id}`."""
    return service.trending(session, provider, identity.user_id)


@router.get("/tv/{tmdb_id}/availability", response_model=AvailabilityResponse)
def tv_availability(
    identity: CallerIdentity, session: DbSession, provider: Provider, tmdb_id: TvId
) -> dict[str, Any]:
    """Where the show streams in the caller's region (JustWatch via TMDB), for
    the show as a whole. Display-only; never ranking."""
    return availability.series_availability(session, provider, identity.user_id, tmdb_id)


@router.get("/tv/{tmdb_id}", response_model=SeriesDetails)
def tv_details(
    identity: CallerIdentity, session: DbSession, provider: Provider, tmdb_id: TvId
) -> SeriesDetails:
    """May refresh the shared series cache; never changes private data."""
    return service.details(session, provider, identity.user_id, tmdb_id)


@router.get("/tv/{tmdb_id}/seasons", response_model=SeasonsResponse)
def tv_seasons(
    identity: CallerIdentity, session: DbSession, provider: Provider, tmdb_id: TvId
) -> SeasonsResponse:
    return service.seasons(session, provider, identity.user_id, tmdb_id)


@router.put("/series/{tmdb_id}/progress")
def put_progress(
    tmdb_id: TvId,
    body: ProgressRequest,
    identity: CallerIdentity,
    session: DbSession,
    provider: Provider,
    idempotency_key: IdempotencyKey = None,
) -> JSONResponse:
    key = idempotency.parse_key(idempotency_key)
    last = (
        None if body.last_watched is None else (body.last_watched.season, body.last_watched.episode)
    )
    status, payload = service.set_progress(
        session, provider, identity.user_id, tmdb_id, body.expected_version, last, key
    )
    return JSONResponse(payload, status_code=status)


@router.post("/series/{tmdb_id}/episodes/watched")
def post_episode_watched(
    tmdb_id: TvId,
    body: WatchedEpisodeRequest,
    identity: CallerIdentity,
    session: DbSession,
    provider: Provider,
    idempotency_key: IdempotencyKey = None,
) -> JSONResponse:
    key = idempotency.parse_key(idempotency_key)
    status, payload = service.mark_next_watched(
        session, provider, identity.user_id, tmdb_id, body.season, body.episode, body.rating, key
    )
    return JSONResponse(payload, status_code=status)


@router.patch("/series/{tmdb_id}/rating")
def patch_series_rating(
    tmdb_id: TvId,
    body: SeriesRatingRequest,
    identity: CallerIdentity,
    session: DbSession,
    provider: Provider,
    idempotency_key: IdempotencyKey = None,
) -> JSONResponse:
    key = idempotency.parse_key(idempotency_key)
    status, payload = service.rate_series(
        session, provider, identity.user_id, tmdb_id, body.rating, key
    )
    return JSONResponse(payload, status_code=status)


@router.patch("/episode-viewings/{viewing_id}")
def patch_episode_rating(
    viewing_id: uuid.UUID,
    body: EpisodeRatingRequest,
    identity: CallerIdentity,
    session: DbSession,
    provider: Provider,
    idempotency_key: IdempotencyKey = None,
) -> JSONResponse:
    key = idempotency.parse_key(idempotency_key)
    status, payload = service.rate_episode(
        session, provider, identity.user_id, viewing_id, body.expected_version, body.rating, key
    )
    return JSONResponse(payload, status_code=status)


@router.get("/episode-viewings")
def get_episode_viewings(
    identity: CallerIdentity,
    session: DbSession,
    provider: Provider,
    limit: Annotated[int, Query(ge=1, le=50)] = 20,
    cursor: Annotated[str | None, Query(max_length=200)] = None,
) -> dict[str, Any]:
    """The caller's watched episodes, newest first."""
    return service.list_viewings(session, provider, identity.user_id, limit, cursor)


@router.get("/me/blocks/series")
def get_series_blocks(
    identity: CallerIdentity, session: DbSession, provider: Provider
) -> dict[str, Any]:
    return service.list_blocks(session, provider, identity.user_id)


@router.post("/me/blocks/series/{tmdb_id}")
def post_series_block(
    tmdb_id: TvId,
    identity: CallerIdentity,
    session: DbSession,
    provider: Provider,
    idempotency_key: IdempotencyKey = None,
) -> JSONResponse:
    key = idempotency.parse_key(idempotency_key)
    status, payload = service.block(session, provider, identity.user_id, tmdb_id, key)
    return JSONResponse(payload, status_code=status)


@router.delete("/me/blocks/series/{tmdb_id}")
def delete_series_block(
    tmdb_id: TvId,
    identity: CallerIdentity,
    session: DbSession,
    idempotency_key: IdempotencyKey = None,
) -> JSONResponse:
    key = idempotency.parse_key(idempotency_key)
    status, payload = service.unblock(session, identity.user_id, tmdb_id, key)
    return JSONResponse(payload, status_code=status)
