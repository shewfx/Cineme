import uuid
from typing import Any
from uuid import UUID

from sqlalchemy import func, select, tuple_
from sqlalchemy.orm import Session

from app.core import idempotency
from app.core.errors import AppError
from app.core.idempotency import lookup, store
from app.movies import service as movies
from app.movies.models import Movie
from app.movies.provider import MovieMetadataProvider
from app.recommendations import service as recommendation_service
from app.users.service import lock_user
from app.viewings.models import Viewing

from .schemas import RatingPatch, RecordViewing


def _body(viewing: Viewing, movie: Movie, names: dict[int, str], base: str) -> dict[str, Any]:
    return recommendation_service.viewing_summary(viewing, movie, names, base)


def list_page(
    db: Session, provider: MovieMetadataProvider, user_id: uuid.UUID, limit: int, cursor: str | None
) -> dict[str, Any]:
    names, base = movies.genre_names(provider), provider.image_base()
    stmt = (
        select(Viewing, Movie)
        .join(Movie, Movie.tmdb_id == Viewing.movie_id)
        .where(Viewing.user_id == user_id)
        .order_by(func.coalesce(Viewing.watched_at, Viewing.recorded_at).desc(), Viewing.id.desc())
        .limit(limit + 1)
    )
    if cursor:
        try:
            anchor_id = UUID(cursor)
        except ValueError as e:
            raise AppError(
                422, "VALIDATION_ERROR", "Invalid history cursor.", details={"fields": ["cursor"]}
            ) from e
        anchor = db.scalar(
            select(Viewing).where(Viewing.id == anchor_id, Viewing.user_id == user_id)
        )
        if anchor is None:
            raise AppError(
                422, "VALIDATION_ERROR", "Invalid history cursor.", details={"fields": ["cursor"]}
            )
        key = func.coalesce(Viewing.watched_at, Viewing.recorded_at)
        stamp = anchor.watched_at or anchor.recorded_at
        stmt = stmt.where(tuple_(key, Viewing.id) < tuple_(stamp, anchor.id))
    rows = db.execute(stmt).all()
    page = rows[:limit]
    today = movies.local_today(db, user_id)
    items = []
    for viewing, movie in page:
        item = recommendation_service.viewing_summary(viewing, movie, names, base)
        item["movie"] = movies.summary(movie, names, base, today).model_dump(mode="json")
        items.append(item)
    return {"items": items, "next_cursor": str(page[-1][0].id) if len(rows) > limit else None}


def record(
    db: Session,
    provider: MovieMetadataProvider,
    user_id: uuid.UUID,
    req: RecordViewing,
    key: uuid.UUID,
) -> tuple[int, dict[str, Any]]:
    operation = "POST /api/v1/viewings"
    body = req.model_dump(mode="json")
    digest = idempotency.request_hash(body)
    replay = lookup(db, user_id, key, operation, digest)
    db.rollback()
    if replay is not None:
        return replay.status, replay.body
    # Provider/network access is outside the user lock and transaction.
    movies.details_cached(db, provider, req.tmdb_id)
    names, base = movies.genre_names(provider), provider.image_base()
    with db.begin():
        user = lock_user(db, user_id)
        replay = lookup(db, user_id, key, operation, digest)
        if replay is not None:
            return replay.status, replay.body
        now = recommendation_service.utc_now()
        watched_at = req.watched_at
        if watched_at is not None and (watched_at.tzinfo is None or watched_at > now):
            raise AppError(
                422,
                "VALIDATION_ERROR",
                "watched_at must be a past date and time.",
                details={"fields": ["watched_at"]},
            )
        movie = db.get(Movie, req.tmdb_id)
        if movie is None or movie.adult or movie.metadata_status != "ready":
            raise AppError(422, "MOVIE_INELIGIBLE", "This film can't be logged.")
        existing = db.scalar(
            select(Viewing).where(Viewing.user_id == user_id, Viewing.movie_id == req.tmdb_id)
        )
        viewing = recommendation_service.record_viewing(
            db,
            user,
            movie,
            watched_at,
            now,
            source="manual",
            rating=req.rating,
        )
        recommendation_service.on_watchlist_removed(db, user, req.tmdb_id, now)
        result = {
            "viewing": _body(viewing, movie, names, base),
            "already_recorded": existing is not None,
            "today": recommendation_service.envelope(db, user, now),
        }
        status = 200 if existing is not None else 201
        store(db, user_id, key, operation, digest, status, result)
    return status, result


def update_rating(
    db: Session,
    provider: MovieMetadataProvider,
    user_id: uuid.UUID,
    viewing_id: uuid.UUID,
    req: RatingPatch,
    key: uuid.UUID,
) -> tuple[int, dict[str, Any]]:
    operation = f"PATCH /api/v1/viewings/{viewing_id}"
    digest = idempotency.request_hash(req.model_dump(mode="json"))
    names, base = movies.genre_names(provider), provider.image_base()
    with db.begin():
        lock_user(db, user_id)
        replay = lookup(db, user_id, key, operation, digest)
        if replay is not None:
            return replay.status, replay.body
        viewing = db.scalar(
            select(Viewing)
            .where(Viewing.id == viewing_id, Viewing.user_id == user_id)
            .with_for_update()
        )
        if viewing is None:
            raise AppError(404, "NOT_FOUND", "That viewing was not found.")
        if viewing.version != req.expected_version:
            raise AppError(409, "VERSION_CONFLICT", "That rating changed. Refresh and try again.")
        viewing.rating = req.rating
        viewing.version += 1
        viewing.updated_at = recommendation_service.utc_now()
        movie = db.get(Movie, viewing.movie_id)
        if movie is None:
            raise AppError(404, "NOT_FOUND", "That film was not found.")
        today = movies.local_today(db, user_id)
        result = recommendation_service.viewing_summary(viewing, movie, names, base)
        result["movie"] = movies.summary(movie, names, base, today).model_dump(mode="json")
        store(db, user_id, key, operation, digest, 200, result)
    return 200, result
