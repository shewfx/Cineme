"""Shows and anime (ADR 011): a shared TMDB metadata cache for series and their
regular episodes, and the caller's own entries, episode history and blocks.
Movie tables are untouched; TV ids live in their own table because TMDB movie
and TV ids overlap."""

import uuid
from datetime import date, datetime
from decimal import Decimal

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    SmallInteger,
    String,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import ARRAY, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class Series(Base):
    """`series`: shared, non-private TMDB metadata. Refreshing it never
    touches a user's entry, progress or history."""

    __tablename__ = "series"
    __table_args__ = (
        CheckConstraint("tmdb_id > 0", name="tmdb_id_positive"),
        CheckConstraint(
            "vote_average IS NULL OR vote_average BETWEEN 0 AND 10", name="vote_average_range"
        ),
        CheckConstraint("vote_count IS NULL OR vote_count >= 0", name="vote_count_nonnegative"),
        CheckConstraint(
            "metadata_status IN ('ready', 'unavailable')", name="metadata_status_values"
        ),
        CheckConstraint(
            "poster_path IS NULL OR poster_path ~ '^/[A-Za-z0-9_-]+\\.(jpg|jpeg|png|webp)$'",
            name="poster_path_relative",
        ),
        CheckConstraint("char_length(btrim(name)) > 0", name="name_not_blank"),
    )

    tmdb_id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=False)
    name: Mapped[str] = mapped_column(Text)
    original_name: Mapped[str | None] = mapped_column(Text)
    first_air_date: Mapped[date | None] = mapped_column(Date)
    last_air_date: Mapped[date | None] = mapped_column(Date)
    status: Mapped[str | None] = mapped_column(Text)
    genre_ids: Mapped[list[int]] = mapped_column(
        ARRAY(Integer), server_default=text("'{}'::integer[]")
    )
    overview: Mapped[str | None] = mapped_column(Text)
    poster_path: Mapped[str | None] = mapped_column(Text)
    original_language: Mapped[str | None] = mapped_column(String(8))
    origin_countries: Mapped[list[str]] = mapped_column(
        ARRAY(Text), server_default=text("'{}'::text[]")
    )
    adult: Mapped[bool] = mapped_column(Boolean)
    vote_average: Mapped[Decimal | None] = mapped_column(Numeric(4, 2))
    vote_count: Mapped[int | None] = mapped_column(Integer)
    metadata_status: Mapped[str] = mapped_column(Text, server_default=text("'ready'"))
    fetched_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    episodes_fetched_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class SeriesEpisode(Base):
    """Regular (season >= 1) episodes only; specials are not stored."""

    __tablename__ = "series_episodes"
    __table_args__ = (
        CheckConstraint("season_number >= 1 AND episode_number >= 1", name="regular_numbers"),
        CheckConstraint(
            "runtime_minutes IS NULL OR runtime_minutes BETWEEN 1 AND 600", name="runtime_range"
        ),
    )

    series_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("cineme.series.tmdb_id", ondelete="CASCADE"), primary_key=True
    )
    season_number: Mapped[int] = mapped_column(SmallInteger, primary_key=True)
    episode_number: Mapped[int] = mapped_column(SmallInteger, primary_key=True)
    tmdb_episode_id: Mapped[int | None] = mapped_column(BigInteger)
    name: Mapped[str | None] = mapped_column(Text)
    air_date: Mapped[date | None] = mapped_column(Date)
    runtime_minutes: Mapped[int | None] = mapped_column(SmallInteger)
    fetched_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class SeriesEntry(Base):
    """A user's series on the watchlist, with saved progress. Removal archives
    the row and keeps progress; re-adding restores it."""

    __tablename__ = "series_entries"
    __table_args__ = (
        UniqueConstraint("user_id", "series_id"),
        CheckConstraint("status IN ('active', 'removed')", name="status_values"),
        CheckConstraint(
            "(status = 'removed') = (removed_at IS NOT NULL)", name="removed_at_matches_status"
        ),
        CheckConstraint(
            "(progress_season IS NULL) = (progress_episode IS NULL)"
            " AND (progress_season IS NULL OR (progress_season >= 1 AND progress_episode >= 1))",
            name="progress_pair",
        ),
        CheckConstraint("progress_version > 0", name="version_positive"),
        CheckConstraint(
            "series_rating IS NULL OR series_rating BETWEEN 1 AND 5", name="rating_range"
        ),
        Index(
            "ix_series_entries_user_id_status_added_at_id", "user_id", "status", "added_at", "id"
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("cineme.users.id", ondelete="CASCADE")
    )
    series_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("cineme.series.tmdb_id", ondelete="RESTRICT")
    )
    status: Mapped[str] = mapped_column(Text, server_default=text("'active'"))
    added_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    removed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    source_type: Mapped[str] = mapped_column(Text, server_default=text("'manual'"))
    progress_season: Mapped[int | None] = mapped_column(SmallInteger)
    progress_episode: Mapped[int | None] = mapped_column(SmallInteger)
    progress_version: Mapped[int] = mapped_column(Integer, server_default=text("1"))
    progress_updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    series_rating: Mapped[int | None] = mapped_column(SmallInteger)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class EpisodeViewing(Base):
    """One confirmed watch per user and episode. The unique key is what makes
    a retry or a second device idempotent. Ratings are stored here and feed no
    score."""

    __tablename__ = "episode_viewings"
    __table_args__ = (
        UniqueConstraint("user_id", "series_id", "season_number", "episode_number"),
        CheckConstraint("season_number >= 1 AND episode_number >= 1", name="regular_numbers"),
        CheckConstraint(
            "source IN ('recommendation', 'manual', 'follow_up')", name="source_values"
        ),
        CheckConstraint("rating IS NULL OR rating BETWEEN 1 AND 5", name="rating_range"),
        CheckConstraint("version > 0", name="version_positive"),
        Index("ix_episode_viewings_user_id_recorded_at", "user_id", text("recorded_at DESC")),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("cineme.users.id", ondelete="CASCADE")
    )
    series_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("cineme.series.tmdb_id", ondelete="RESTRICT")
    )
    season_number: Mapped[int] = mapped_column(SmallInteger)
    episode_number: Mapped[int] = mapped_column(SmallInteger)
    watched_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    source: Mapped[str] = mapped_column(Text)
    recommendation_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("cineme.recommendations.id", ondelete="SET NULL")
    )
    rating: Mapped[int | None] = mapped_column(SmallInteger)
    version: Mapped[int] = mapped_column(Integer, server_default=text("1"))
    genre_ids_snapshot: Mapped[list[int]] = mapped_column(
        ARRAY(Integer), server_default=text("'{}'::integer[]")
    )
    episode_name_snapshot: Mapped[str | None] = mapped_column(Text)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class SeriesBlock(Base):
    """Reversible Never recommend for a series; leaves the entry and progress
    alone."""

    __tablename__ = "series_blocks"
    __table_args__ = (CheckConstraint("reason = 'never_recommend'", name="reason"),)

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("cineme.users.id", ondelete="CASCADE"), primary_key=True
    )
    series_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("cineme.series.tmdb_id", ondelete="RESTRICT"), primary_key=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    reason: Mapped[str] = mapped_column(Text, server_default=text("'never_recommend'"))
