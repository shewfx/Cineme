"""Episode history and the progress pointer, shared by the series API and
Tonight. Imports no service module, so recommendations can use it."""

import uuid
from datetime import date, datetime
from typing import Any

from sqlalchemy import or_, select, tuple_
from sqlalchemy.dialects.postgresql import distinct_on, insert
from sqlalchemy.orm import Session

from app.core.errors import AppError

from . import episodes
from .models import EpisodeViewing, Series, SeriesEntry, SeriesEpisode


def to_ep(row: SeriesEpisode) -> episodes.Ep:
    return episodes.Ep(
        season=row.season_number,
        episode=row.episode_number,
        name=row.name,
        air_date=row.air_date,
        runtime_minutes=row.runtime_minutes,
    )


def progress_of(entry: SeriesEntry) -> tuple[int, int] | None:
    if entry.progress_season is None or entry.progress_episode is None:
        return None
    return (entry.progress_season, entry.progress_episode)


def first_after(
    session: Session, series_id: int, progress: tuple[int, int] | None
) -> episodes.Ep | None:
    stmt = (
        select(SeriesEpisode)
        .where(SeriesEpisode.series_id == series_id)
        .order_by(SeriesEpisode.season_number, SeriesEpisode.episode_number)
        .limit(1)
    )
    if progress is not None:
        stmt = stmt.where(
            tuple_(SeriesEpisode.season_number, SeriesEpisode.episode_number) > tuple_(*progress)
        )
    row = session.scalar(stmt)
    return to_ep(row) if row is not None else None


def next_for(session: Session, entry: SeriesEntry, series: Series, today: date) -> episodes.Next:
    return episodes.next_state(
        first_after(session, series.tmdb_id, progress_of(entry)),
        has_data=series.episodes_fetched_at is not None,
        status=series.status,
        today=today,
    )


def next_candidates(session: Session, user_id: uuid.UUID) -> dict[int, episodes.Ep]:
    """For every active entry of the user: the first regular episode after the
    saved progress, in one query (series without one are absent)."""
    stmt = (
        select(SeriesEpisode)
        .join(
            SeriesEntry,
            (SeriesEntry.series_id == SeriesEpisode.series_id)
            & (SeriesEntry.user_id == user_id)
            & (SeriesEntry.status == "active"),
        )
        .where(
            or_(
                SeriesEntry.progress_season.is_(None),
                tuple_(SeriesEpisode.season_number, SeriesEpisode.episode_number)
                > tuple_(SeriesEntry.progress_season, SeriesEntry.progress_episode),
            )
        )
        .order_by(
            SeriesEpisode.series_id, SeriesEpisode.season_number, SeriesEpisode.episode_number
        )
        .ext(distinct_on(SeriesEpisode.series_id))
    )
    return {row.series_id: to_ep(row) for row in session.scalars(stmt)}


def record_episode_viewing(
    session: Session,
    user_id: uuid.UUID,
    entry: SeriesEntry,
    series: Series,
    episode: episodes.Ep,
    now: datetime,
    *,
    source: str,
    rating: int | None = None,
    recommendation_id: uuid.UUID | None = None,
) -> tuple[EpisodeViewing, bool]:
    """Records one confirmed watch (unique per user and episode) and moves the
    pointer forward only. Returns (viewing, created). A replay or a second
    device finds the existing viewing and changes nothing."""
    values: dict[str, Any] = {
        "id": uuid.uuid4(),
        "user_id": user_id,
        "series_id": series.tmdb_id,
        "season_number": episode.season,
        "episode_number": episode.episode,
        "watched_at": now,
        "recorded_at": now,
        "source": source,
        "recommendation_id": recommendation_id,
        "rating": rating,
        "version": 1,
        "genre_ids_snapshot": list(series.genre_ids),
        "episode_name_snapshot": episode.name,
        "updated_at": now,
    }
    inserted = session.execute(
        insert(EpisodeViewing)
        .values(**values)
        .on_conflict_do_nothing(
            index_elements=["user_id", "series_id", "season_number", "episode_number"]
        )
        .returning(EpisodeViewing.id)
    ).scalar_one_or_none()
    viewing = session.scalar(
        select(EpisodeViewing).where(
            EpisodeViewing.user_id == user_id,
            EpisodeViewing.series_id == series.tmdb_id,
            EpisodeViewing.season_number == episode.season,
            EpisodeViewing.episode_number == episode.episode,
        )
    )
    if viewing is None:  # pragma: no cover (just inserted or conflicting row exists)
        raise AppError(500, "INTERNAL_ERROR", "Couldn't record this episode.")
    if episodes.is_after(episode.season, episode.episode, progress_of(entry)):
        entry.progress_season = episode.season
        entry.progress_episode = episode.episode
        entry.progress_version += 1
        entry.progress_updated_at = now
        entry.updated_at = now
    session.flush()
    return viewing, inserted is not None
