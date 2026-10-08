"""Search, details and the shared metadata cache (ARCHITECTURE "Cache and
freshness"). Network calls happen outside any user lock; the movie cache is
shared, non-private data and may be written by a GET."""

import uuid
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from typing import Literal
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.core.errors import AppError
from app.users.blocks import MovieBlock
from app.users.models import User
from app.viewings.models import Viewing
from app.watchlist.models import WatchlistEntry

from .models import Movie
from .provider import GenreRef, MovieMetadataProvider, ProviderMovie, poster_url
from .schemas import (
    GenreOut,
    MovieDetails,
    MovieSummary,
    PopularResponse,
    SearchResponse,
    TraitsOut,
    TrendingResponse,
)

FRESH_FOR = timedelta(days=7)


def local_today(session: Session, user_id: uuid.UUID) -> date:
    """The caller's current date in their profile timezone; 409 without a
    profile (no secret bootstrap)."""
    zone = session.scalar(select(User.timezone).where(User.id == user_id))
    if zone is None:
        raise AppError(409, "PROFILE_NOT_INITIALIZED", "Your Cinemé profile is not set up yet.")
    return datetime.now(ZoneInfo(zone)).date()


def can_add(adult: bool) -> bool:
    """Adult films are never stored. Upcoming and unknown-date films may be
    saved; storage is not Tonight eligibility (see `is_released`)."""
    return not adult


def is_released(release_date: date | None, today: date) -> bool:
    """Tonight eligibility gate for P4: only a known release date on or before
    the user's local date counts. Unknown stays ineligible until refreshed
    metadata establishes a date."""
    return release_date is not None and release_date <= today


def genre_names(provider: MovieMetadataProvider) -> dict[int, str]:
    try:
        return {g.id: g.name for g in provider.genres()}
    except AppError:
        return {}  # ids stay complete; names are optional display data


def _genres(ids: Iterable[int], names: dict[int, str]) -> list[GenreOut]:
    return [GenreOut(id=i, name=names[i]) for i in ids if i in names]


def search(
    session: Session,
    provider: MovieMetadataProvider,
    user_id: uuid.UUID,
    query: str,
    page: int,
) -> SearchResponse:
    today = local_today(session, user_id)
    session.rollback()  # no open transaction during network calls
    result = provider.search(query, page)
    names = genre_names(provider)
    base = provider.image_base()
    ids = [m.tmdb_id for m in result.results]
    # Runtime only when details are already cached; never fetched per result.
    rows = session.execute(
        select(Movie.tmdb_id, Movie.runtime_minutes).where(
            Movie.tmdb_id.in_(ids), Movie.metadata_status == "ready"
        )
    ).all()
    session.rollback()
    cached = {tmdb_id: runtime for tmdb_id, runtime in rows}
    return SearchResponse(
        page=result.page,
        total_pages=result.total_pages,
        results=[
            MovieSummary(
                tmdb_id=m.tmdb_id,
                title=m.title,
                year=m.release_date.year if m.release_date else None,
                runtime_minutes=cached.get(m.tmdb_id),
                genre_ids=list(m.genre_ids),
                genres=_genres(m.genre_ids, names),
                poster_url=poster_url(base, m.poster_path),
                can_add=can_add(m.adult),
                released=is_released(m.release_date, today),
            )
            for m in result.results
        ],
    )


TRENDING_LIMIT = 12


def _discovery(
    session: Session,
    provider: MovieMetadataProvider,
    user_id: uuid.UUID,
    fetch: Callable[[date], tuple[ProviderMovie, ...]],
) -> tuple[list[MovieSummary], list[int]]:
    """Shared discovery presentation. `fetch` gets the caller's local date and
    returns TMDB films (the same for everyone, cached in the provider). They
    are filtered to what the caller can actually add: not adult, released, with
    a poster, not already watched and not blocked by this user; at most
    TRENDING_LIMIT remain. Never a recommendation."""
    today = local_today(session, user_id)
    session.rollback()  # no open transaction during network calls
    films = fetch(today)
    names = genre_names(provider)
    base = provider.image_base()
    candidates = [
        m
        for m in films
        if can_add(m.adult)
        and is_released(m.release_date, today)
        and poster_url(base, m.poster_path)
    ]
    ids = [m.tmdb_id for m in candidates]
    watched = set(
        session.scalars(
            select(Viewing.movie_id).where(Viewing.user_id == user_id, Viewing.movie_id.in_(ids))
        )
    )
    blocked = set(
        session.scalars(
            select(MovieBlock.movie_id).where(
                MovieBlock.user_id == user_id, MovieBlock.movie_id.in_(ids)
            )
        )
    )
    shown = [m for m in candidates if m.tmdb_id not in watched | blocked][:TRENDING_LIMIT]
    saved = set(
        session.scalars(
            select(WatchlistEntry.movie_id).where(
                WatchlistEntry.user_id == user_id,
                WatchlistEntry.status == "active",
                WatchlistEntry.movie_id.in_([m.tmdb_id for m in shown]),
            )
        )
    )
    session.rollback()
    results = [
        MovieSummary(
            tmdb_id=m.tmdb_id,
            title=m.title,
            year=m.release_date.year if m.release_date else None,
            runtime_minutes=None,
            genre_ids=list(m.genre_ids),
            genres=_genres(m.genre_ids, names),
            poster_url=poster_url(base, m.poster_path),
            vote_average=m.vote_average,
            can_add=True,
            released=True,
        )
        for m in shown
    ]
    return results, [m.tmdb_id for m in shown if m.tmdb_id in saved]


def trending(
    session: Session, provider: MovieMetadataProvider, user_id: uuid.UUID
) -> TrendingResponse:
    """This week's trending films (TMDB), for onboarding and Watchlist add."""
    results, saved = _discovery(session, provider, user_id, lambda _today: provider.trending())
    return TrendingResponse(results=results, in_watchlist=saved)


def popular_releases(
    session: Session,
    provider: MovieMetadataProvider,
    user_id: uuid.UUID,
    period: Literal["month", "year"],
) -> PopularResponse:
    """Films released this calendar month or year up to the caller's local
    today, by current TMDB popularity. These are popular releases, not a
    historical monthly or yearly trending ranking."""
    window: list[date] = []

    def fetch(today: date) -> tuple[ProviderMovie, ...]:
        start = today.replace(day=1) if period == "month" else today.replace(month=1, day=1)
        window[:] = [start, today]
        return provider.popular_releases(start, today)

    results, saved = _discovery(session, provider, user_id, fetch)
    return PopularResponse(
        period=period,
        released_from=window[0],
        released_to=window[1],
        results=results,
        in_watchlist=saved,
    )


def upsert_movie(session: Session, m: ProviderMovie) -> None:
    """Refreshes shared metadata only; user watchlist rows are untouched."""
    now = datetime.now(UTC)
    values = {
        "title": m.title,
        "original_title": m.original_title,
        "release_date": m.release_date,
        "runtime_minutes": m.runtime_minutes,
        "genre_ids": list(m.genre_ids),
        "overview": m.overview,
        "poster_path": m.poster_path,
        "original_language": m.original_language,
        "adult": m.adult,
        "vote_average": m.vote_average,
        "vote_count": m.vote_count,
        "metadata_status": "ready",
        "fetched_at": now,
    }
    session.execute(
        insert(Movie)
        .values(tmdb_id=m.tmdb_id, **values)
        .on_conflict_do_update(index_elements=[Movie.tmdb_id], set_={**values, "updated_at": now})
    )


@dataclass(frozen=True)
class CachedMovie:
    movie: Movie
    stale: bool


def details_cached(session: Session, provider: MovieMetadataProvider, tmdb_id: int) -> CachedMovie:
    """Fresh cache, else fetch and store; on upstream failure fall back to an
    existing (stale) row. Adult films are never stored. Raises without a
    usable prior row."""
    cached = session.get(Movie, tmdb_id)
    if cached is not None and cached.fetched_at > datetime.now(UTC) - FRESH_FOR:
        session.rollback()
        return CachedMovie(cached, stale=False)
    session.rollback()
    try:
        fetched = provider.details(tmdb_id)
    except AppError as e:
        if cached is not None and e.status in (429, 502, 503):
            return CachedMovie(cached, stale=True)
        raise
    if fetched.adult:
        raise AppError(422, "MOVIE_INELIGIBLE", "This film can't be added to Cinemé.")
    with session.begin():
        upsert_movie(session, fetched)
    movie = session.get(Movie, tmdb_id)
    session.rollback()
    if movie is None:  # deleted concurrently; treat like an unavailable upstream
        raise AppError(503, "DEPENDENCY_UNAVAILABLE", "Try again shortly.", retryable=True)
    return CachedMovie(movie, stale=False)


def summary(movie: Movie, names: dict[int, str], image_base: str, today: date) -> MovieSummary:
    return MovieSummary(
        tmdb_id=movie.tmdb_id,
        title=movie.title,
        year=movie.release_date.year if movie.release_date else None,
        runtime_minutes=movie.runtime_minutes,
        vote_average=float(movie.vote_average) if movie.vote_average is not None else None,
        genre_ids=list(movie.genre_ids),
        genres=_genres(movie.genre_ids, names),
        poster_url=poster_url(image_base, movie.poster_path),
        can_add=movie.metadata_status == "ready" and can_add(movie.adult),
        released=is_released(movie.release_date, today),
    )


def details(
    session: Session, provider: MovieMetadataProvider, user_id: uuid.UUID, tmdb_id: int
) -> MovieDetails:
    today = local_today(session, user_id)
    session.rollback()
    found = details_cached(session, provider, tmdb_id)
    m = found.movie
    base = summary(m, genre_names(provider), provider.image_base(), today)
    return MovieDetails(
        **base.model_dump(),
        release_date=m.release_date,
        overview=m.overview,
        original_title=m.original_title,
        original_language=m.original_language,
        vote_count=m.vote_count,
        metadata_fetched_at=m.fetched_at,
        stale=found.stale,
        traits=TraitsOut(),
    )


def genre_list(provider: MovieMetadataProvider) -> list[GenreRef]:
    return list(provider.genres())
