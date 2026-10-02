"""Per-user watchlist inventory. Membership means eligibility, not taste:
nothing here touches preferences or learning."""

import base64
import binascii
import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import func, select, tuple_
from sqlalchemy.orm import Session

from app.core import idempotency
from app.core.errors import AppError
from app.movies import service as movies
from app.movies.models import Movie
from app.movies.provider import MovieMetadataProvider
from app.recommendations import service as today
from app.users.service import lock_user

from .models import WatchlistEntry
from .schemas import AddResponse, WatchlistItem, WatchlistPage

ACTIVE_LIMIT = 500


def _encode_cursor(added_at: datetime, entry_id: uuid.UUID) -> str:
    raw = f"{added_at.isoformat()}|{entry_id}".encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _decode_cursor(cursor: str) -> tuple[datetime, uuid.UUID]:
    try:
        raw = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)).decode()
        stamp, entry_id = raw.split("|", 1)
        return datetime.fromisoformat(stamp), uuid.UUID(entry_id)
    except (ValueError, binascii.Error, UnicodeDecodeError) as e:
        raise AppError(
            422, "VALIDATION_ERROR", "Invalid cursor.", details={"fields": ["cursor"]}
        ) from e


def _escape_like(text: str) -> str:
    return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _item(
    entry: WatchlistEntry, movie: Movie, names: dict[int, str], base: str, local: Any
) -> WatchlistItem:
    return WatchlistItem(
        id=entry.id,
        movie=movies.summary(movie, names, base, local),
        added_at=entry.added_at,
        source_type=entry.source_type,
    )


def list_entries(
    session: Session,
    provider: MovieMetadataProvider,
    user_id: uuid.UUID,
    limit: int,
    cursor: str | None,
    q: str | None,
) -> WatchlistPage:
    """Active entries, added_at DESC then id DESC. Reads only this user's rows
    and the local cache: works while TMDB is down."""
    local = movies.local_today(session, user_id)
    stmt = (
        select(WatchlistEntry, Movie)
        .join(Movie, Movie.tmdb_id == WatchlistEntry.movie_id)
        .where(WatchlistEntry.user_id == user_id, WatchlistEntry.status == "active")
        .order_by(WatchlistEntry.added_at.desc(), WatchlistEntry.id.desc())
        .limit(limit + 1)
    )
    if cursor:
        added_at, entry_id = _decode_cursor(cursor)
        stmt = stmt.where(
            tuple_(WatchlistEntry.added_at, WatchlistEntry.id) < tuple_(added_at, entry_id)
        )
    if q:
        stmt = stmt.where(Movie.title.ilike(f"%{_escape_like(q)}%", escape="\\"))
    rows = session.execute(stmt).all()
    session.rollback()
    names = movies.genre_names(provider)  # cached in process; optional
    base = provider.image_base()
    page = rows[:limit]
    next_cursor = (
        _encode_cursor(page[-1][0].added_at, page[-1][0].id) if len(rows) > limit else None
    )
    return WatchlistPage(
        items=[_item(e, m, names, base, local) for e, m in page], next_cursor=next_cursor
    )


def add(
    session: Session,
    provider: MovieMetadataProvider,
    user_id: uuid.UUID,
    tmdb_id: int,
    key: uuid.UUID,
) -> tuple[int, dict[str, Any]]:
    """Returns (status, body). Duplicate active add -> 200 already_present;
    new or restored -> 201. Restoring resets added_at."""
    operation = "POST /api/v1/watchlist"
    digest = idempotency.request_hash({"tmdb_id": tmdb_id})

    # Preflight: an identical committed retry is replayed without network.
    replay = idempotency.lookup(session, user_id, key, operation, digest)
    session.rollback()
    if replay is not None:
        return replay.status, replay.body

    movies.details_cached(session, provider, tmdb_id)  # network outside the lock
    names = movies.genre_names(provider)
    base = provider.image_base()

    with session.begin():
        user = lock_user(session, user_id)
        replay = idempotency.lookup(session, user_id, key, operation, digest)
        if replay is not None:
            return replay.status, replay.body
        local = movies.local_today(session, user_id)
        movie = session.get(Movie, tmdb_id)
        if movie is None or movie.metadata_status != "ready" or not movies.can_add(movie.adult):
            raise AppError(422, "MOVIE_INELIGIBLE", "This film can't be added to CinemÃ©.")
        entry = session.scalar(
            select(WatchlistEntry).where(
                WatchlistEntry.user_id == user_id, WatchlistEntry.movie_id == tmdb_id
            )
        )
        now = today.utc_now()
        if entry is not None and entry.status == "active":
            status, already = 200, True
        else:
            active = session.scalar(
                select(func.count())
                .select_from(WatchlistEntry)
                .where(WatchlistEntry.user_id == user_id, WatchlistEntry.status == "active")
            )
            if (active or 0) >= ACTIVE_LIMIT:
                raise AppError(
                    409,
                    "WATCHLIST_LIMIT",
                    f"Your watchlist is full ({ACTIVE_LIMIT} films). Remove one to add another.",
                )
            if entry is None:
                entry = WatchlistEntry(
                    id=uuid.uuid4(),
                    user_id=user_id,
                    movie_id=tmdb_id,
                    status="active",
                    added_at=now,
                    source_type="manual",
                )
                session.add(entry)
            else:  # restore an archived entry; its age starts again
                entry.status = "active"
                entry.removed_at = None
                entry.added_at = now
                entry.updated_at = now
            status, already = 201, False
            today.on_watchlist_added(session, user, now)
        session.flush()
        body = AddResponse(
            entry=_item(entry, movie, names, base, local),
            already_present=already,
            today=today.envelope(session, user, now),
        ).model_dump(mode="json")
        idempotency.store(session, user_id, key, operation, digest, status, body)
    return status, body


def remove(
    session: Session, user_id: uuid.UUID, entry_id: uuid.UUID, key: uuid.UUID
) -> tuple[int, dict[str, Any]]:
    """Archives the caller's entry. Someone else's or unknown id -> 404, never
    a leaked 403. Already removed succeeds."""
    operation = f"DELETE /api/v1/watchlist/{entry_id}"
    digest = idempotency.request_hash({})
    with session.begin():
        user = lock_user(session, user_id)
        replay = idempotency.lookup(session, user_id, key, operation, digest)
        if replay is not None:
            return replay.status, replay.body
        entry = session.scalar(
            select(WatchlistEntry)
            .where(WatchlistEntry.id == entry_id, WatchlistEntry.user_id == user_id)
            .with_for_update()
        )
        if entry is None:
            raise AppError(404, "NOT_FOUND", "That watchlist entry was not found.")
        if entry.status == "active":
            now = today.utc_now()
            entry.status = "removed"
            entry.removed_at = now
            entry.updated_at = now
            today.on_watchlist_removed(session, user, entry.movie_id, now)
        session.flush()
        body: dict[str, Any] = {"removed": True, "today": today.envelope(session, user)}
        idempotency.store(session, user_id, key, operation, digest, 200, body)
    return 200, body
