from typing import Annotated

from fastapi import APIRouter, Depends, Header, Request, Response
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session

from app.core import idempotency
from app.core.auth import Identity, IdentityProvider, current_identity
from app.core.db import get_session
from app.core.errors import AppError
from app.recommendations import service as today
from app.users.models import UserPreferences

from . import service
from .schemas import (
    BootstrapResponse,
    MePatch,
    MeResponse,
    PreferencesPatch,
    PreferencesResponse,
    PreferencesUpdate,
)

router = APIRouter(prefix="/api/v1/me", tags=["me"])

CallerIdentity = Annotated[Identity, Depends(current_identity)]
DbSession = Annotated[Session, Depends(get_session)]


@router.post(
    "/bootstrap",
    response_model=BootstrapResponse,
    responses={201: {"model": BootstrapResponse}},
)
def bootstrap_me(
    request: Request, response: Response, identity: CallerIdentity, session: DbSession
) -> BootstrapResponse:
    """Explicitly create (201) or reuse (200) the caller's profile. Naturally
    idempotent, so exempt from the Idempotency-Key ledger."""
    if not service.profile_exists(session, identity.user_id):
        session.rollback()  # no open transaction during the provider call
        provider: IdentityProvider = request.app.state.identity_provider
        provider.confirm(identity)
    else:
        session.rollback()
    profile, created = service.bootstrap(session, identity.user_id)
    response.status_code = 201 if created else 200
    return BootstrapResponse(profile=profile, created=created)


@router.get("", response_model=MeResponse)
def get_me(identity: CallerIdentity, session: DbSession) -> MeResponse:
    """Read-only. 409 PROFILE_NOT_INITIALIZED until bootstrap succeeds."""
    return service.read_profile(session, identity.user_id)


@router.patch("", response_model=MeResponse)
def patch_me(
    patch: MePatch,
    identity: CallerIdentity,
    session: DbSession,
    idempotency_key: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
) -> JSONResponse:
    """Display name and/or timezone. Same key + same body replays the stored
    response; same key + different body is 409 IDEMPOTENCY_CONFLICT."""
    key = idempotency.parse_key(idempotency_key)
    digest = idempotency.request_hash(patch.model_dump(mode="json", exclude_unset=True))
    operation = "PATCH /api/v1/me"
    with session.begin():
        user = service.lock_user(session, identity.user_id)
        replay = idempotency.lookup(session, user.id, key, operation, digest)
        if replay is not None:
            return JSONResponse(replay.body, status_code=replay.status)
        service.apply_patch(user, patch)
        session.flush()
        body = service.read_profile(session, user.id).model_dump(mode="json")
        idempotency.store(session, user.id, key, operation, digest, 200, body)
    return JSONResponse(body, status_code=200)


@router.get("/preferences", response_model=PreferencesResponse)
def get_preferences(identity: CallerIdentity, session: DbSession) -> PreferencesResponse:
    return service.read_profile(session, identity.user_id).preferences


@router.patch("/preferences", response_model=PreferencesUpdate)
def patch_preferences(
    patch: PreferencesPatch,
    identity: CallerIdentity,
    session: DbSession,
    idempotency_key: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
) -> JSONResponse:
    """Recommendation-affecting changes (genre preferences, blocked genres,
    runtime cap) clear today's open pick; they never choose a replacement."""
    key = idempotency.parse_key(idempotency_key)
    digest = idempotency.request_hash(patch.model_dump(mode="json", exclude_unset=True))
    operation = "PATCH /api/v1/me/preferences"
    with session.begin():
        user = service.lock_user(session, identity.user_id)
        replay = idempotency.lookup(session, user.id, key, operation, digest)
        if replay is not None:
            return JSONResponse(replay.body, status_code=replay.status)
        prefs = session.get(UserPreferences, user.id)
        if prefs is None:
            raise AppError(409, "PROFILE_NOT_INITIALIZED", "Your Cinemé profile is not set up yet.")
        _, affecting = service.apply_preferences(prefs, patch)
        now = today.utc_now()
        if affecting:
            today.on_preferences_changed(session, user, now)
        session.flush()
        body = {
            "preferences": service.preferences_out(prefs).model_dump(mode="json"),
            "today": today.envelope(session, user, now),
        }
        idempotency.store(session, user.id, key, operation, digest, 200, body)
    return JSONResponse(body, status_code=200)
