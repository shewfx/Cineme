"""Profile bootstrap, read and edit. Every query is scoped to the verified
caller's id; no request supplies a user id."""

import uuid
from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.core.errors import AppError

from .models import User, UserPreferences
from .schemas import MePatch, MeResponse, PreferencesResponse


def _not_initialized() -> AppError:
    return AppError(
        409,
        "PROFILE_NOT_INITIALIZED",
        "Your Cinemé profile is not set up yet.",
    )


def profile_exists(session: Session, user_id: uuid.UUID) -> bool:
    return session.get(User, user_id) is not None


def read_profile(session: Session, user_id: uuid.UUID) -> MeResponse:
    """GET /me: read-only. Never inserts or resets."""
    row = session.execute(
        select(User, UserPreferences)
        .join(UserPreferences, UserPreferences.user_id == User.id)
        .where(User.id == user_id)
    ).one_or_none()
    if row is None:
        raise _not_initialized()
    user, prefs = row
    return MeResponse(
        id=user.id,
        display_name=user.display_name,
        timezone=user.timezone,
        created_at=user.created_at,
        preferences=PreferencesResponse(
            version=prefs.version,
            genre_preferences=prefs.genre_preferences,
            blocked_genre_ids=prefs.blocked_genre_ids,
            default_max_runtime_minutes=prefs.default_max_runtime_minutes,
            ai_context_enabled=prefs.ai_context_enabled,
        ),
    )


def bootstrap(session: Session, user_id: uuid.UUID) -> tuple[MeResponse, bool]:
    """Create the profile and default preferences once. Concurrent first calls
    converge through insert-on-conflict in one transaction; a retry never
    resets existing fields. Returns (profile, created)."""
    with session.begin():
        created = (
            session.execute(
                insert(User)
                .values(id=user_id)
                .on_conflict_do_nothing(index_elements=[User.id])
                .returning(User.id)
            ).scalar_one_or_none()
            is not None
        )
        session.execute(
            insert(UserPreferences)
            .values(user_id=user_id)
            .on_conflict_do_nothing(index_elements=[UserPreferences.user_id])
        )
    return read_profile(session, user_id), created


def lock_user(session: Session, user_id: uuid.UUID) -> User:
    """Private mutations lock the caller's users row first (DATA_MODEL
    "Atomicity and concurrency"); 409 if no profile exists."""
    user = session.scalar(select(User).where(User.id == user_id).with_for_update())
    if user is None:
        raise _not_initialized()
    return user


def apply_patch(user: User, patch: MePatch) -> None:
    """Explicit last-write values; only supplied fields change."""
    changed = False
    if "display_name" in patch.model_fields_set and patch.display_name != user.display_name:
        user.display_name = patch.display_name
        changed = True
    if (
        "timezone" in patch.model_fields_set
        and patch.timezone is not None
        and patch.timezone != user.timezone
    ):
        user.timezone = patch.timezone
        changed = True
    if changed:
        user.updated_at = datetime.now(UTC)
