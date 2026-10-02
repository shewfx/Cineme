from typing import Annotated

from fastapi import APIRouter, Depends, Header, Request, Response
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session

from app.core import idempotency
from app.core.auth import Identity, IdentityProvider, current_identity
from app.core.db import get_session

from . import service
from .schemas import BootstrapResponse, MePatch, MeResponse

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
