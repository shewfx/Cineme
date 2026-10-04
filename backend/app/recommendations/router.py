import uuid
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header, Query
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session

from app.core import idempotency
from app.core.auth import Identity, current_identity
from app.core.db import get_session
from app.core.errors import AppError
from app.movies import service as movies
from app.movies.router import Provider
from app.users.models import User

from . import service
from .schemas import (
    AcceptRequest,
    ChooseRequest,
    ComparisonResponse,
    ContextPatch,
    FollowUpAction,
    HistoryPage,
    MarkWatchedRequest,
    RecommendationDetail,
    RejectRequest,
    RejectResponse,
    TodayEnvelope,
)

router = APIRouter(prefix="/api/v1", tags=["today"])

CallerIdentity = Annotated[Identity, Depends(current_identity)]
DbSession = Annotated[Session, Depends(get_session)]
IdempotencyKey = Annotated[str | None, Header(alias="Idempotency-Key")]


def _display(provider: Provider) -> tuple[dict[int, str], str]:
    """Genre names and poster base, fetched before any lock (cached)."""
    return movies.genre_names(provider), provider.image_base()


@router.get("/today", response_model=TodayEnvelope)
def get_today(identity: CallerIdentity, session: DbSession) -> JSONResponse:
    """Read-only: never creates a session, picks a film or records an offer."""
    user = session.get(User, identity.user_id)
    if user is None:
        raise AppError(409, "PROFILE_NOT_INITIALIZED", "Your Cinemé profile is not set up yet.")
    body = service.envelope(session, user)
    session.rollback()
    return JSONResponse(body)


@router.patch("/today/context", response_model=TodayEnvelope)
def patch_context(
    body: ContextPatch,
    identity: CallerIdentity,
    session: DbSession,
    idempotency_key: IdempotencyKey = None,
) -> JSONResponse:
    key = idempotency.parse_key(idempotency_key)
    status, payload = service.patch_context(session, identity.user_id, body, key)
    return JSONResponse(payload, status_code=status)


@router.post(
    "/today/choose",
    response_model=TodayEnvelope,
    status_code=201,
    responses={200: {"model": TodayEnvelope, "description": "Existing pick unchanged"}},
)
def choose(
    body: ChooseRequest,
    identity: CallerIdentity,
    session: DbSession,
    provider: Provider,
    idempotency_key: IdempotencyKey = None,
) -> JSONResponse:
    key = idempotency.parse_key(idempotency_key)
    names, base = _display(provider)
    status, payload = service.choose(session, identity.user_id, body, key, names, base)
    return JSONResponse(payload, status_code=status)


@router.post("/recommendations/{rec_id}/accept", response_model=TodayEnvelope)
def accept(
    rec_id: uuid.UUID,
    body: AcceptRequest,
    identity: CallerIdentity,
    session: DbSession,
    idempotency_key: IdempotencyKey = None,
) -> JSONResponse:
    key = idempotency.parse_key(idempotency_key)
    status, payload = service.accept(
        session, identity.user_id, rec_id, body.expected_session_version, key
    )
    return JSONResponse(payload, status_code=status)


@router.post("/recommendations/{rec_id}/follow-up", response_model=TodayEnvelope)
def follow_up(
    rec_id: uuid.UUID,
    body: FollowUpAction,
    identity: CallerIdentity,
    session: DbSession,
    idempotency_key: IdempotencyKey = None,
) -> JSONResponse:
    key = idempotency.parse_key(idempotency_key)
    status, payload = service.follow_up_action(session, identity.user_id, rec_id, body.action, key)
    return JSONResponse(payload, status_code=status)


@router.post("/recommendations/{rec_id}/watched", response_model=None)
def mark_watched(
    rec_id: uuid.UUID,
    body: MarkWatchedRequest,
    identity: CallerIdentity,
    session: DbSession,
    provider: Provider,
    idempotency_key: IdempotencyKey = None,
) -> JSONResponse:
    key = idempotency.parse_key(idempotency_key)
    names, base = _display(provider)
    status, payload = service.mark_watched(
        session,
        identity.user_id,
        rec_id,
        body.expected_session_version,
        body.rating,
        key,
        names,
        base,
    )
    return JSONResponse(payload, status_code=status)


@router.post("/recommendations/{rec_id}/reject", response_model=RejectResponse)
def reject(
    rec_id: uuid.UUID,
    body: RejectRequest,
    identity: CallerIdentity,
    session: DbSession,
    provider: Provider,
    idempotency_key: IdempotencyKey = None,
) -> JSONResponse:
    key = idempotency.parse_key(idempotency_key)
    names, base = _display(provider)
    status, payload = service.reject(session, identity.user_id, rec_id, body, key, names, base)
    return JSONResponse(payload, status_code=status)


@router.get("/recommendations", response_model=HistoryPage)
def list_recommendations(
    identity: CallerIdentity,
    session: DbSession,
    limit: Annotated[int, Query(ge=1, le=50)] = 20,
    cursor: Annotated[str | None, Query(max_length=200)] = None,
    status: Literal["offered", "accepted", "rejected", "watched", "superseded", "no_match"]
    | None = None,
) -> JSONResponse:
    body = service.history(session, identity.user_id, limit, cursor, status)
    session.rollback()
    return JSONResponse(body)


@router.get("/recommendations/{rec_id}", response_model=RecommendationDetail)
def get_recommendation(
    rec_id: uuid.UUID, identity: CallerIdentity, session: DbSession
) -> JSONResponse:
    body = service.detail(session, identity.user_id, rec_id)
    session.rollback()
    return JSONResponse(body)


@router.get("/recommendations/{rec_id}/comparison", response_model=ComparisonResponse)
def get_comparison(rec_id: uuid.UUID, identity: CallerIdentity, session: DbSession) -> JSONResponse:
    """Engineering view of retained scores; never used for Tonight choices."""
    body = service.comparison(session, identity.user_id, rec_id)
    session.rollback()
    return JSONResponse(body)
