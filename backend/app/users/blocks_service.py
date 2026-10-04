import base64
import json
import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import select, tuple_
from sqlalchemy.orm import Session

from app.core import idempotency
from app.core.errors import AppError
from app.movies import service as movies
from app.movies.models import Movie
from app.movies.provider import MovieMetadataProvider
from app.recommendations import service as today
from app.users.blocks import MovieBlock
from app.users.service import lock_user


def list_blocks(
    db: Session,
    provider: MovieMetadataProvider,
    user_id: uuid.UUID,
    limit: int = 20,
    cursor: str | None = None,
) -> dict[str, Any]:
    names, base = movies.genre_names(provider), provider.image_base()
    stmt = (
        select(MovieBlock, Movie)
        .join(Movie, Movie.tmdb_id == MovieBlock.movie_id)
        .where(MovieBlock.user_id == user_id)
        .order_by(MovieBlock.created_at.desc(), MovieBlock.movie_id.desc())
    )
    if cursor:
        try:
            stamp_raw, movie_raw = json.loads(base64.urlsafe_b64decode(cursor + "=="))
            stamp, movie_id = datetime.fromisoformat(stamp_raw), int(movie_raw)
        except Exception as exc:
            raise AppError(
                422, "VALIDATION_ERROR", "Invalid blocks cursor.", details={"fields": ["cursor"]}
            ) from exc
        stmt = stmt.where(
            tuple_(MovieBlock.created_at, MovieBlock.movie_id) < tuple_(stamp, movie_id)
        )
    rows = db.execute(stmt.limit(limit + 1)).all()
    page = rows[:limit]
    today_local = movies.local_today(db, user_id)
    return {
        "items": [
            {
                "movie": movies.summary(m, names, base, today_local).model_dump(mode="json"),
                "blocked_at": block.created_at,
            }
            for block, m in page
        ],
        "next_cursor": (
            base64.urlsafe_b64encode(
                json.dumps([page[-1][0].created_at.isoformat(), page[-1][0].movie_id]).encode()
            )
            .decode()
            .rstrip("=")
            if len(rows) > limit
            else None
        ),
    }


def block(
    db: Session, provider: MovieMetadataProvider, user_id: uuid.UUID, tmdb_id: int, key: uuid.UUID
) -> tuple[int, dict[str, Any]]:
    operation = f"POST /api/v1/me/blocks/{tmdb_id}"
    digest = idempotency.request_hash({})
    # Provider lookups stay outside the user lock; retry preflight avoids a
    # metadata request for a command the ledger already committed.
    preflight = idempotency.lookup(db, user_id, key, operation, digest)
    if preflight is not None:
        db.rollback()
        return preflight.status, preflight.body
    db.rollback()
    movies.details_cached(db, provider, tmdb_id)
    with db.begin():
        user = lock_user(db, user_id)
        replay = idempotency.lookup(db, user_id, key, operation, digest)
        if replay is not None:
            return replay.status, replay.body
        movie = db.get(Movie, tmdb_id)
        if movie is None or movie.adult or movie.metadata_status != "ready":
            raise AppError(422, "MOVIE_INELIGIBLE", "This film can't be blocked.")
        exists = db.get(MovieBlock, (user_id, tmdb_id)) is not None
        if not exists:
            db.add(MovieBlock(user_id=user_id, movie_id=tmdb_id))
            today.on_movie_blocked(db, user, tmdb_id, today.utc_now())
        body = {
            "blocked": True,
            "already_blocked": exists,
            "today": today.envelope(db, user, today.utc_now()),
        }
        idempotency.store(db, user_id, key, operation, digest, 200, body)
    return 200, body


def unblock(
    db: Session, user_id: uuid.UUID, tmdb_id: int, key: uuid.UUID
) -> tuple[int, dict[str, Any]]:
    operation = f"DELETE /api/v1/me/blocks/{tmdb_id}"
    digest = idempotency.request_hash({})
    with db.begin():
        user = lock_user(db, user_id)
        replay = idempotency.lookup(db, user_id, key, operation, digest)
        if replay is not None:
            return replay.status, replay.body
        block_row = db.get(MovieBlock, (user_id, tmdb_id))
        if block_row is not None:
            db.delete(block_row)
            today.on_movie_unblocked(db, user, tmdb_id, today.utc_now())
        body = {
            "unblocked": True,
            "watchlist_restored": False,
            "today": today.envelope(db, user, today.utc_now()),
        }
        idempotency.store(db, user_id, key, operation, digest, 200, body)
    return 200, body
