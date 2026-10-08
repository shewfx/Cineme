"""Series metadata, the caller's series entries, progress and episode watches
(ADR 011). Network calls (TMDB) happen outside any user lock; every private
mutation locks the users row first, replays an identical idempotent retry and
only then changes anything."""

import base64
import binascii
import contextlib
import time
import uuid
from collections.abc import Callable, Sequence
from datetime import date, datetime, timedelta
from typing import Any

from sqlalchemy import delete, func, select, tuple_
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.core import idempotency
from app.core.errors import AppError
from app.movies import service as movies
from app.movies.provider import (
    MovieMetadataProvider,
    ProviderEpisode,
    ProviderSeries,
    poster_url,
)
from app.recommendations import service as today
from app.users.service import lock_user
from app.watchlist.models import WatchlistEntry

from . import display, episodes, history
from .models import EpisodeViewing, Series, SeriesBlock, SeriesEntry, SeriesEpisode
from .schemas import (
    LIMITATIONS,
    EpisodeOut,
    EpisodeViewingOut,
    NextOut,
    ProgressOut,
    SeasonOut,
    SeasonsResponse,
    SeriesDetails,
    SeriesEntryOut,
    SeriesSummary,
    TrendingShowsResponse,
    TvSearchResponse,
)

ACTIVE_LIMIT = 500
FRESH_AIRING = timedelta(days=1)
FRESH_ENDED = timedelta(days=7)


# --- display ---------------------------------------------------------------------------


def can_add(adult: bool) -> bool:
    return not adult


summary = display.summary
_genres = display.genres


def provider_summary(s: ProviderSeries, names: dict[int, str], base: str) -> SeriesSummary:
    return SeriesSummary(
        tmdb_id=s.tmdb_id,
        name=s.name,
        year=s.first_air_date.year if s.first_air_date else None,
        status=s.status,
        genre_ids=list(s.genre_ids),
        genres=_genres(s.genre_ids, names),
        poster_url=poster_url(base, s.poster_path),
        vote_average=s.vote_average,
        can_add=can_add(s.adult),
    )


def episode_out(e: episodes.Ep) -> EpisodeOut:
    return EpisodeOut(
        season_number=e.season,
        episode_number=e.episode,
        name=e.name,
        air_date=e.air_date,
        runtime_minutes=e.runtime_minutes,
    )


def next_out(n: episodes.Next) -> NextOut:
    return NextOut(
        state=n.state,
        episode=episode_out(n.episode) if n.episode is not None else None,
    )


def entry_out(
    entry: SeriesEntry,
    series: Series,
    next_: episodes.Next,
    names: dict[int, str],
    base: str,
) -> SeriesEntryOut:
    progress = history.progress_of(entry)
    return SeriesEntryOut(
        id=entry.id,
        series=summary(series, names, base),
        added_at=entry.added_at,
        progress=ProgressOut(
            season=progress[0], episode=progress[1], version=entry.progress_version
        )
        if progress
        else None,
        progress_version=entry.progress_version,
        next=next_out(next_),
        series_rating=entry.series_rating,
    )


def entries_out(
    session: Session,
    user_id: uuid.UUID,
    rows: Sequence[tuple[SeriesEntry, Series]],
    names: dict[int, str],
    base: str,
    local: date,
) -> list[SeriesEntryOut]:
    """Entries with their next-episode state, derived from one batched query."""
    candidates = history.next_candidates(session, user_id)
    return [
        entry_out(
            e,
            s,
            episodes.next_state(
                candidates.get(s.tmdb_id),
                has_data=s.episodes_fetched_at is not None,
                status=s.status,
                today=local,
            ),
            names,
            base,
        )
        for e, s in rows
    ]


# --- metadata cache ----------------------------------------------------------------------


def _ttl(status: str | None) -> timedelta:
    return FRESH_ENDED if status in episodes.ENDED_STATUSES else FRESH_AIRING


def upsert_series(
    session: Session, s: ProviderSeries, eps: Sequence[ProviderEpisode], now: datetime
) -> None:
    """Refreshes shared metadata and the regular-episode cache; never touches
    user entries, progress or history."""
    values: dict[str, Any] = {
        "name": s.name,
        "original_name": s.original_name,
        "first_air_date": s.first_air_date,
        "last_air_date": s.last_air_date,
        "status": s.status,
        "genre_ids": list(s.genre_ids),
        "overview": s.overview,
        "poster_path": s.poster_path,
        "original_language": s.original_language,
        "origin_countries": list(s.origin_countries),
        "adult": s.adult,
        "vote_average": s.vote_average,
        "vote_count": s.vote_count,
        "metadata_status": "ready",
        "fetched_at": now,
        "episodes_fetched_at": now,
    }
    session.execute(
        insert(Series)
        .values(tmdb_id=s.tmdb_id, **values)
        .on_conflict_do_update(index_elements=[Series.tmdb_id], set_={**values, "updated_at": now})
    )
    session.execute(delete(SeriesEpisode).where(SeriesEpisode.series_id == s.tmdb_id))
    if eps:
        session.execute(
            insert(SeriesEpisode),
            [
                {
                    "series_id": s.tmdb_id,
                    "season_number": e.season_number,
                    "episode_number": e.episode_number,
                    "tmdb_episode_id": e.tmdb_episode_id,
                    "name": e.name,
                    "air_date": e.air_date,
                    "runtime_minutes": e.runtime_minutes,
                    "fetched_at": now,
                }
                for e in eps
            ],
        )


def ensure_series(session: Session, provider: MovieMetadataProvider, tmdb_id: int) -> bool:
    """Makes sure the series and its regular episodes are cached and fresh
    (returning shows after a day, ended ones after a week). Fetches outside any
    transaction. On an upstream failure a stale cache is served (returns True);
    without a cache the failure is raised. Adult series are never stored."""
    cached = session.get(Series, tmdb_id)
    snapshot = (
        None if cached is None else (cached.status, cached.fetched_at, cached.episodes_fetched_at)
    )
    session.rollback()
    now = today.utc_now()
    if snapshot and snapshot[2] and now - min(snapshot[1], snapshot[2]) < _ttl(snapshot[0]):
        return False
    try:
        fetched = provider.tv_details(tmdb_id)
        eps = provider.tv_episodes(tmdb_id, [n for n, _ in fetched.seasons])
    except AppError as e:
        if snapshot is not None and e.status in (429, 502, 503):
            return True
        raise
    if fetched.adult:
        raise AppError(422, "SERIES_INELIGIBLE", "This show can't be added to Cinemé.")
    with session.begin():
        upsert_series(session, fetched, eps, now)
    return False


REFRESH_LIMIT = 3
REFRESH_BUDGET_SECONDS = 12.0


def refresh_stale(session: Session, provider: MovieMetadataProvider, user_id: uuid.UUID) -> None:
    """Before Tonight picks: refresh at most REFRESH_LIMIT of the caller's
    stale shows (never-loaded first, then the oldest) within a small time
    budget, outside any lock. A returning show whose cache is a day old may
    have aired a new episode; there are no background jobs, so this is where
    "caught up" can end. Failures are ignored: the stale cache is used."""
    now = today.utc_now()
    rows = session.execute(
        select(Series.tmdb_id, Series.status, Series.fetched_at, Series.episodes_fetched_at)
        .join(SeriesEntry, SeriesEntry.series_id == Series.tmdb_id)
        .where(SeriesEntry.user_id == user_id, SeriesEntry.status == "active")
    ).all()
    session.rollback()
    stale = sorted(
        (
            (eps is not None, min(fetched, eps) if eps is not None else fetched, sid)
            for sid, status, fetched, eps in rows
            if eps is None or now - min(fetched, eps) >= _ttl(status)
        ),
    )
    started = time.monotonic()
    for _, _, sid in stale[:REFRESH_LIMIT]:
        if time.monotonic() - started > REFRESH_BUDGET_SECONDS:
            break
        with contextlib.suppress(AppError):
            ensure_series(session, provider, sid)


TRENDING_LIMIT = 12


def trending(
    session: Session, provider: MovieMetadataProvider, user_id: uuid.UUID
) -> TrendingShowsResponse:
    """This week's trending shows (anime included) for the add screen: the same
    list for everyone, then filtered for this caller: no adult shows, nothing
    without a poster, nothing the caller blocked, at most TRENDING_LIMIT. Shows
    already on the watchlist stay (they read Added), and an ongoing show is
    never dropped because some episodes were watched. Not a recommendation."""
    movies.local_today(session, user_id)  # 409 without a profile
    session.rollback()
    shows = provider.trending_tv()
    names = movies.genre_names(provider)
    base = provider.image_base()
    candidates = [s for s in shows if can_add(s.adult) and poster_url(base, s.poster_path)]
    ids = [s.tmdb_id for s in candidates]
    blocked = set(
        session.scalars(
            select(SeriesBlock.series_id).where(
                SeriesBlock.user_id == user_id, SeriesBlock.series_id.in_(ids)
            )
        )
    )
    shown = [s for s in candidates if s.tmdb_id not in blocked][:TRENDING_LIMIT]
    saved = set(
        session.scalars(
            select(SeriesEntry.series_id).where(
                SeriesEntry.user_id == user_id,
                SeriesEntry.status == "active",
                SeriesEntry.series_id.in_([s.tmdb_id for s in shown]),
            )
        )
    )
    session.rollback()
    return TrendingShowsResponse(
        results=[provider_summary(s, names, base) for s in shown],
        in_watchlist=[s.tmdb_id for s in shown if s.tmdb_id in saved],
    )


def search(
    session: Session, provider: MovieMetadataProvider, user_id: uuid.UUID, query: str, page: int
) -> TvSearchResponse:
    movies.local_today(session, user_id)  # 409 without a profile
    session.rollback()
    result = provider.search_tv(query, page)
    names = movies.genre_names(provider)
    base = provider.image_base()
    return TvSearchResponse(
        page=result.page,
        total_pages=result.total_pages,
        results=[provider_summary(s, names, base) for s in result.results],
    )


def details(
    session: Session, provider: MovieMetadataProvider, user_id: uuid.UUID, tmdb_id: int
) -> SeriesDetails:
    local = movies.local_today(session, user_id)
    session.rollback()
    stale = ensure_series(session, provider, tmdb_id)
    names = movies.genre_names(provider)
    base = provider.image_base()
    series = session.get(Series, tmdb_id)
    if series is None:
        raise AppError(404, "NOT_FOUND", "That show was not found.")
    entry = session.scalar(
        select(SeriesEntry).where(
            SeriesEntry.user_id == user_id,
            SeriesEntry.series_id == tmdb_id,
            SeriesEntry.status == "active",
        )
    )
    out = None
    if entry is not None:
        out = entry_out(entry, series, history.next_for(session, entry, series, local), names, base)
    season_count = (
        session.scalar(
            select(func.count(func.distinct(SeriesEpisode.season_number))).where(
                SeriesEpisode.series_id == tmdb_id
            )
        )
        or 0
    )
    result = SeriesDetails(
        series=summary(series, names, base),
        original_name=series.original_name,
        overview=series.overview,
        first_air_date=series.first_air_date,
        last_air_date=series.last_air_date,
        origin_countries=list(series.origin_countries),
        season_count=season_count,
        stale=stale,
        limitations=LIMITATIONS,
        entry=out,
    )
    session.rollback()
    return result


def seasons(
    session: Session, provider: MovieMetadataProvider, user_id: uuid.UUID, tmdb_id: int
) -> SeasonsResponse:
    movies.local_today(session, user_id)
    session.rollback()
    ensure_series(session, provider, tmdb_id)
    rows = session.scalars(
        select(SeriesEpisode)
        .where(SeriesEpisode.series_id == tmdb_id)
        .order_by(SeriesEpisode.season_number, SeriesEpisode.episode_number)
    ).all()
    by_season: dict[int, list[EpisodeOut]] = {}
    for r in rows:
        by_season.setdefault(r.season_number, []).append(episode_out(history.to_ep(r)))
    result = SeasonsResponse(
        seasons=[SeasonOut(season_number=n, episodes=eps) for n, eps in sorted(by_season.items())],
        limitations=LIMITATIONS,
    )
    session.rollback()
    return result


# --- commands ------------------------------------------------------------------------------


def _command(
    session: Session,
    user_id: uuid.UUID,
    key: uuid.UUID,
    operation: str,
    body: dict[str, Any],
    run: Callable[[Any, datetime], tuple[int, dict[str, Any]]],
) -> tuple[int, dict[str, Any]]:
    """Lock the users row, replay an identical committed retry, else run and
    store the response in the same transaction."""
    digest = idempotency.request_hash(body)
    with session.begin():
        user = lock_user(session, user_id)
        replay = idempotency.lookup(session, user_id, key, operation, digest)
        if replay is not None:
            return replay.status, replay.body
        status, payload = run(user, today.utc_now())
        session.flush()
        idempotency.store(session, user_id, key, operation, digest, status, payload)
    return status, payload


def _display(provider: MovieMetadataProvider) -> tuple[dict[int, str], str]:
    return movies.genre_names(provider), provider.image_base()


def active_total(session: Session, user_id: uuid.UUID) -> int:
    movies_n = session.scalar(
        select(func.count())
        .select_from(WatchlistEntry)
        .where(WatchlistEntry.user_id == user_id, WatchlistEntry.status == "active")
    )
    shows_n = session.scalar(
        select(func.count())
        .select_from(SeriesEntry)
        .where(SeriesEntry.user_id == user_id, SeriesEntry.status == "active")
    )
    return (movies_n or 0) + (shows_n or 0)


def _own_entry(session: Session, user_id: uuid.UUID, tmdb_id: int) -> SeriesEntry:
    entry = session.scalar(
        select(SeriesEntry)
        .where(
            SeriesEntry.user_id == user_id,
            SeriesEntry.series_id == tmdb_id,
            SeriesEntry.status == "active",
        )
        .with_for_update()
    )
    if entry is None:
        raise AppError(404, "NOT_FOUND", "That show is not on your watchlist.")
    return entry


def add(
    session: Session,
    provider: MovieMetadataProvider,
    user_id: uuid.UUID,
    tmdb_id: int,
    key: uuid.UUID,
) -> tuple[int, dict[str, Any]]:
    """POST /watchlist for a series. Duplicate active add is 200
    already_present; new or restored is 201. Restoring keeps progress."""
    operation = "POST /api/v1/watchlist"
    body = {"media_type": "series", "tmdb_id": tmdb_id}
    digest = idempotency.request_hash(body)
    replay = idempotency.lookup(session, user_id, key, operation, digest)
    session.rollback()
    if replay is not None:
        return replay.status, replay.body
    ensure_series(session, provider, tmdb_id)  # network outside the lock
    names, base = _display(provider)

    def run(user: Any, now: datetime) -> tuple[int, dict[str, Any]]:
        local = today.local_date_for(user, now)
        series = session.get(Series, tmdb_id)
        if series is None or series.metadata_status != "ready" or not can_add(series.adult):
            raise AppError(422, "SERIES_INELIGIBLE", "This show can't be added to Cinemé.")
        if session.get(SeriesBlock, (user_id, tmdb_id)) is not None:
            raise AppError(
                409, "SERIES_BLOCKED", "You chose never to recommend this show. Unblock it first."
            )
        entry = session.scalar(
            select(SeriesEntry).where(
                SeriesEntry.user_id == user_id, SeriesEntry.series_id == tmdb_id
            )
        )
        if entry is not None and entry.status == "active":
            status, already = 200, True
        else:
            if active_total(session, user_id) >= ACTIVE_LIMIT:
                raise AppError(
                    409,
                    "WATCHLIST_LIMIT",
                    f"Your watchlist is full ({ACTIVE_LIMIT} titles). Remove one to add another.",
                )
            if entry is None:
                entry = SeriesEntry(
                    id=uuid.uuid4(),
                    user_id=user_id,
                    series_id=tmdb_id,
                    status="active",
                    added_at=now,
                    source_type="manual",
                    progress_version=1,
                )
                session.add(entry)
            else:  # restore: the age starts again, progress is kept
                entry.status = "active"
                entry.removed_at = None
                entry.added_at = now
                entry.updated_at = now
            status, already = 201, False
            today.on_watchlist_added(session, user, now)
        session.flush()
        next_ = history.next_for(session, entry, series, local)
        payload = {
            "entry": entry_out(entry, series, next_, names, base).model_dump(mode="json"),
            "already_present": already,
            "today": today.envelope(session, user, now),
        }
        return status, payload

    return _command(session, user_id, key, operation, body, run)


def set_progress(
    session: Session,
    provider: MovieMetadataProvider,
    user_id: uuid.UUID,
    tmdb_id: int,
    expected_version: int,
    last: tuple[int, int] | None,
    key: uuid.UUID,
) -> tuple[int, dict[str, Any]]:
    """Saves "Last watched: Season N, Episode M" (or not started). Creates no
    viewings, never counts toward continuity, and supersedes an open pick for
    this show without choosing a replacement."""
    operation = f"PUT /api/v1/series/{tmdb_id}/progress"
    body = {
        "expected_version": expected_version,
        "last_watched": None if last is None else {"season": last[0], "episode": last[1]},
    }
    digest = idempotency.request_hash(body)
    replay = idempotency.lookup(session, user_id, key, operation, digest)
    session.rollback()
    if replay is not None:
        return replay.status, replay.body
    try:
        ensure_series(session, provider, tmdb_id)
    except AppError:
        if last is not None:
            raise
    names, base = _display(provider)

    def run(user: Any, now: datetime) -> tuple[int, dict[str, Any]]:
        local = today.local_date_for(user, now)
        entry = _own_entry(session, user_id, tmdb_id)
        series = session.get(Series, tmdb_id)
        if series is None:  # pragma: no cover (FK)
            raise AppError(404, "NOT_FOUND", "That show was not found.")
        if entry.progress_version != expected_version:
            raise AppError(
                409,
                "VERSION_CONFLICT",
                "Your progress changed elsewhere. Refresh and try again.",
                details={
                    "current_version": entry.progress_version,
                    "progress": None
                    if history.progress_of(entry) is None
                    else {
                        "season": entry.progress_season,
                        "episode": entry.progress_episode,
                    },
                },
            )
        if last is not None:
            target = session.get(SeriesEpisode, (tmdb_id, last[0], last[1]))
            if target is None:
                raise AppError(
                    422,
                    "EPISODE_NOT_FOUND",
                    "TMDB doesn't list that episode in the regular seasons.",
                )
            if not episodes.has_aired(target.air_date, local):
                raise AppError(422, "EPISODE_NOT_AIRED", "That episode hasn't aired yet.")
        if last != history.progress_of(entry):
            entry.progress_season = None if last is None else last[0]
            entry.progress_episode = None if last is None else last[1]
            entry.progress_version += 1
            entry.progress_updated_at = now
            entry.updated_at = now
            today.on_series_progress_changed(session, user, tmdb_id, now)
        session.flush()
        payload = {
            "entry": entry_out(
                entry, series, history.next_for(session, entry, series, local), names, base
            ).model_dump(mode="json"),
            "today": today.envelope(session, user, now),
        }
        return 200, payload

    return _command(session, user_id, key, operation, body, run)


def viewing_out(
    v: EpisodeViewing, series: Series | None, names: dict[int, str], base: str
) -> EpisodeViewingOut:
    return EpisodeViewingOut(
        id=v.id,
        series=summary(series, names, base) if series is not None else None,
        season_number=v.season_number,
        episode_number=v.episode_number,
        episode_name=v.episode_name_snapshot,
        watched_at=v.watched_at,
        recorded_at=v.recorded_at,
        source=v.source,
        rating=v.rating,
        version=v.version,
        recommendation_id=v.recommendation_id,
    )


def mark_next_watched(
    session: Session,
    provider: MovieMetadataProvider,
    user_id: uuid.UUID,
    tmdb_id: int,
    season: int,
    episode: int,
    rating: int | None,
    key: uuid.UUID,
) -> tuple[int, dict[str, Any]]:
    """Records the show's NEXT episode as watched and advances the pointer in
    one transaction. Any other episode is refused (never a silent skip); to
    jump ahead the user sets their progress explicitly."""
    operation = f"POST /api/v1/series/{tmdb_id}/episodes/watched"
    body = {"season": season, "episode": episode, "rating": rating}
    digest = idempotency.request_hash(body)
    replay = idempotency.lookup(session, user_id, key, operation, digest)
    session.rollback()
    if replay is not None:
        return replay.status, replay.body
    names, base = _display(provider)

    def run(user: Any, now: datetime) -> tuple[int, dict[str, Any]]:
        local = today.local_date_for(user, now)
        entry = _own_entry(session, user_id, tmdb_id)
        series = session.get(Series, tmdb_id)
        if series is None:  # pragma: no cover (FK)
            raise AppError(404, "NOT_FOUND", "That show was not found.")
        existing = session.scalar(
            select(EpisodeViewing).where(
                EpisodeViewing.user_id == user_id,
                EpisodeViewing.series_id == tmdb_id,
                EpisodeViewing.season_number == season,
                EpisodeViewing.episode_number == episode,
            )
        )
        nxt = history.next_for(session, entry, series, local)
        if existing is None:
            if nxt.episode is None or nxt.episode.key != (season, episode):
                raise AppError(
                    409,
                    "NOT_NEXT_EPISODE",
                    "That isn't the next episode. Set your progress to jump ahead.",
                    details={
                        "next": None
                        if nxt.episode is None
                        else {
                            "season_number": nxt.episode.season,
                            "episode_number": nxt.episode.episode,
                        },
                        "state": nxt.state,
                    },
                )
            if nxt.state != episodes.UP_NEXT:
                raise AppError(409, "EPISODE_NOT_AIRED", "That episode hasn't aired yet.")
            ep = nxt.episode
        else:
            ep = episodes.Ep(season, episode, existing.episode_name_snapshot)
        viewing, created = history.record_episode_viewing(
            session, user_id, entry, series, ep, now, source="manual", rating=rating
        )
        if created:
            today.on_series_progress_changed(session, user, tmdb_id, now)
        session.flush()
        payload = {
            "entry": entry_out(
                entry, series, history.next_for(session, entry, series, local), names, base
            ).model_dump(mode="json"),
            "viewing": viewing_out(viewing, series, names, base).model_dump(mode="json"),
            "already_recorded": not created,
            "today": today.envelope(session, user, now),
        }
        return 200, payload

    return _command(session, user_id, key, operation, body, run)


def rate_episode(
    session: Session,
    provider: MovieMetadataProvider,
    user_id: uuid.UUID,
    viewing_id: uuid.UUID,
    expected_version: int,
    rating: int | None,
    key: uuid.UUID,
) -> tuple[int, dict[str, Any]]:
    """Episode rating (not a series rating). Stored and shown; it feeds no
    score. Edits replace the single rating and are version-checked."""
    operation = f"PATCH /api/v1/episode-viewings/{viewing_id}"
    body = {"expected_version": expected_version, "rating": rating}
    names, base = _display(provider)

    def run(user: Any, now: datetime) -> tuple[int, dict[str, Any]]:
        viewing = session.scalar(
            select(EpisodeViewing)
            .where(EpisodeViewing.id == viewing_id, EpisodeViewing.user_id == user_id)
            .with_for_update()
        )
        if viewing is None:
            raise AppError(404, "NOT_FOUND", "That episode record was not found.")
        if viewing.version != expected_version:
            raise AppError(
                409,
                "VERSION_CONFLICT",
                "That rating changed elsewhere. Refresh and try again.",
                details={"current_version": viewing.version},
            )
        if viewing.rating != rating:
            viewing.rating = rating
            viewing.version += 1
            viewing.updated_at = now
        series = session.get(Series, viewing.series_id)
        return 200, {
            "viewing": viewing_out(viewing, series, names, base).model_dump(mode="json"),
            "today": today.envelope(session, user, now),
        }

    return _command(session, user_id, key, operation, body, run)


def rate_series(
    session: Session,
    provider: MovieMetadataProvider,
    user_id: uuid.UUID,
    tmdb_id: int,
    rating: int | None,
    key: uuid.UUID,
) -> tuple[int, dict[str, Any]]:
    """Series rating, separate from episode ratings; it feeds no score."""
    operation = f"PATCH /api/v1/series/{tmdb_id}/rating"
    body = {"rating": rating}
    names, base = _display(provider)

    def run(user: Any, now: datetime) -> tuple[int, dict[str, Any]]:
        local = today.local_date_for(user, now)
        entry = _own_entry(session, user_id, tmdb_id)
        series = session.get(Series, tmdb_id)
        if series is None:  # pragma: no cover (FK)
            raise AppError(404, "NOT_FOUND", "That show was not found.")
        if entry.series_rating != rating:
            entry.series_rating = rating
            entry.updated_at = now
        return 200, {
            "entry": entry_out(
                entry, series, history.next_for(session, entry, series, local), names, base
            ).model_dump(mode="json"),
            "today": today.envelope(session, user, now),
        }

    return _command(session, user_id, key, operation, body, run)


# --- blocks ----------------------------------------------------------------------------------


def list_viewings(
    session: Session,
    provider: MovieMetadataProvider,
    user_id: uuid.UUID,
    limit: int,
    cursor: str | None,
) -> dict[str, Any]:
    """Episode history, newest first (watched time, else recorded time).
    Separate from film history: the movie viewings API is unchanged."""
    names, base = _display(provider)
    when = func.coalesce(EpisodeViewing.watched_at, EpisodeViewing.recorded_at)
    stmt = (
        select(EpisodeViewing, Series, when.label("at"))
        .join(Series, Series.tmdb_id == EpisodeViewing.series_id)
        .where(EpisodeViewing.user_id == user_id)
        .order_by(when.desc(), EpisodeViewing.id.desc())
        .limit(limit + 1)
    )
    if cursor:
        try:
            raw = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)).decode()
            stamp, vid = raw.split("|", 1)
            at, viewing_id = datetime.fromisoformat(stamp), uuid.UUID(vid)
        except (ValueError, binascii.Error, UnicodeDecodeError) as e:
            raise AppError(
                422, "VALIDATION_ERROR", "Invalid cursor.", details={"fields": ["cursor"]}
            ) from e
        stmt = stmt.where(tuple_(when, EpisodeViewing.id) < tuple_(at, viewing_id))
    rows = session.execute(stmt).all()
    page = rows[:limit]
    result = {
        "items": [viewing_out(v, s, names, base).model_dump(mode="json") for v, s, _ in page],
        "next_cursor": (
            base64.urlsafe_b64encode(f"{page[-1][2].isoformat()}|{page[-1][0].id}".encode())
            .decode()
            .rstrip("=")
            if len(rows) > limit
            else None
        ),
    }
    session.rollback()
    return result


def block(
    session: Session,
    provider: MovieMetadataProvider,
    user_id: uuid.UUID,
    tmdb_id: int,
    key: uuid.UUID,
) -> tuple[int, dict[str, Any]]:
    operation = f"POST /api/v1/me/blocks/series/{tmdb_id}"
    digest = idempotency.request_hash({})
    replay = idempotency.lookup(session, user_id, key, operation, digest)
    session.rollback()
    if replay is not None:
        return replay.status, replay.body
    ensure_series(session, provider, tmdb_id)

    def run(user: Any, now: datetime) -> tuple[int, dict[str, Any]]:
        series = session.get(Series, tmdb_id)
        if series is None or series.adult or series.metadata_status != "ready":
            raise AppError(422, "SERIES_INELIGIBLE", "This show can't be blocked.")
        exists = session.get(SeriesBlock, (user_id, tmdb_id)) is not None
        if not exists:
            session.add(SeriesBlock(user_id=user_id, series_id=tmdb_id))
            today.on_series_blocked(session, user, tmdb_id, now)
        return 200, {
            "blocked": True,
            "already_blocked": exists,
            "today": today.envelope(session, user, now),
        }

    return _command(session, user_id, key, operation, {}, run)


def unblock(
    session: Session, user_id: uuid.UUID, tmdb_id: int, key: uuid.UUID
) -> tuple[int, dict[str, Any]]:
    operation = f"DELETE /api/v1/me/blocks/series/{tmdb_id}"

    def run(user: Any, now: datetime) -> tuple[int, dict[str, Any]]:
        row = session.get(SeriesBlock, (user_id, tmdb_id))
        if row is not None:
            session.delete(row)
            today.on_series_unblocked(session, user, tmdb_id, now)
        return 200, {
            "unblocked": True,
            "today": today.envelope(session, user, now),
        }

    return _command(session, user_id, key, operation, {}, run)


def list_blocks(
    session: Session, provider: MovieMetadataProvider, user_id: uuid.UUID
) -> dict[str, Any]:
    """Blocked shows, newest first (the list is short; no cursor)."""
    names, base = _display(provider)
    rows = session.execute(
        select(SeriesBlock, Series)
        .join(Series, Series.tmdb_id == SeriesBlock.series_id)
        .where(SeriesBlock.user_id == user_id)
        .order_by(SeriesBlock.created_at.desc(), SeriesBlock.series_id.desc())
        .limit(200)
    ).all()
    result = {
        "items": [
            {
                "series": summary(s, names, base).model_dump(mode="json"),
                "blocked_at": b.created_at,
            }
            for b, s in rows
        ]
    }
    session.rollback()
    return result
