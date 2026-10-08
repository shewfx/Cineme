"""Profile bootstrap, read and edit. Every query is scoped to the verified
caller's id; no request supplies a user id."""

import uuid
from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.core.errors import AppError
from app.movies.availability import region_for

from .models import User, UserPreferences
from .schemas import MePatch, MeResponse, PreferencesPatch, PreferencesResponse


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
        country_code=user.country_code,
        region=region_for(user),
        created_at=user.created_at,
        onboarding_completed_at=user.onboarding_completed_at,
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
    if "country_code" in patch.model_fields_set and patch.country_code != user.country_code:
        user.country_code = patch.country_code
        changed = True
    # One-way and monotonic: a repeat never moves the original timestamp.
    if patch.onboarding_completed and user.onboarding_completed_at is None:
        user.onboarding_completed_at = datetime.now(UTC)
        changed = True
    if changed:
        user.updated_at = datetime.now(UTC)


def preferences_out(prefs: UserPreferences) -> PreferencesResponse:
    return PreferencesResponse(
        version=prefs.version,
        genre_preferences=prefs.genre_preferences,
        blocked_genre_ids=prefs.blocked_genre_ids,
        default_max_runtime_minutes=prefs.default_max_runtime_minutes,
        ai_context_enabled=prefs.ai_context_enabled,
    )


def apply_preferences(prefs: UserPreferences, patch: PreferencesPatch) -> tuple[bool, bool]:
    """Returns (changed, recommendation-affecting). Version conflicts 409."""
    if patch.expected_version != prefs.version:
        raise AppError(
            409,
            "VERSION_CONFLICT",
            "Your preferences changed elsewhere. Refresh and try again.",
            details={"current_version": prefs.version},
        )
    supplied = patch.model_fields_set
    affecting = False
    changed = False
    if "genre_preferences" in supplied and patch.genre_preferences != prefs.genre_preferences:
        prefs.genre_preferences = patch.genre_preferences or {}
        affecting = True
    if "blocked_genre_ids" in supplied and sorted(patch.blocked_genre_ids or []) != sorted(
        prefs.blocked_genre_ids
    ):
        prefs.blocked_genre_ids = sorted(patch.blocked_genre_ids or [])
        affecting = True
    if (
        "default_max_runtime_minutes" in supplied
        and patch.default_max_runtime_minutes != prefs.default_max_runtime_minutes
    ):
        prefs.default_max_runtime_minutes = patch.default_max_runtime_minutes
        affecting = True
    if (
        "ai_context_enabled" in supplied
        and patch.ai_context_enabled is not None
        and patch.ai_context_enabled != prefs.ai_context_enabled
    ):
        prefs.ai_context_enabled = patch.ai_context_enabled
        changed = True
    changed = changed or affecting
    if changed:
        prefs.version += 1
        prefs.updated_at = datetime.now(UTC)
    return changed, affecting
