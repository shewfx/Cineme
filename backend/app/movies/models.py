from datetime import date, datetime
from decimal import Decimal

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    Date,
    DateTime,
    Integer,
    Numeric,
    SmallInteger,
    String,
    Text,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import ARRAY
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class Movie(Base):
    """`movies` (DATA_MODEL): shared, non-private TMDB metadata cache keyed by
    TMDB id. Refreshing it never touches user watchlist state. No raw
    upstream JSON, credits or traits are stored."""

    __tablename__ = "movies"
    __table_args__ = (
        CheckConstraint("tmdb_id > 0", name="tmdb_id_positive"),
        CheckConstraint(
            "runtime_minutes IS NULL OR runtime_minutes BETWEEN 1 AND 600",
            name="runtime_range",
        ),
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
        CheckConstraint("char_length(btrim(title)) > 0", name="title_not_blank"),
    )

    tmdb_id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=False)
    title: Mapped[str] = mapped_column(Text)
    original_title: Mapped[str | None] = mapped_column(Text)
    release_date: Mapped[date | None] = mapped_column(Date)
    runtime_minutes: Mapped[int | None] = mapped_column(SmallInteger)
    genre_ids: Mapped[list[int]] = mapped_column(
        ARRAY(Integer), server_default=text("'{}'::integer[]")
    )
    overview: Mapped[str | None] = mapped_column(Text)
    poster_path: Mapped[str | None] = mapped_column(Text)
    original_language: Mapped[str | None] = mapped_column(String(8))
    adult: Mapped[bool]
    vote_average: Mapped[Decimal | None] = mapped_column(Numeric(4, 2))
    vote_count: Mapped[int | None] = mapped_column(Integer)
    metadata_status: Mapped[str] = mapped_column(Text, server_default=text("'ready'"))
    fetched_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
