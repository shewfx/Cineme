import uuid
from datetime import datetime

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    SmallInteger,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import ARRAY, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class Viewing(Base):
    """`viewings` (DATA_MODEL), brought forward by ADR 006 for "Already
    watched" only. One known viewing per user and film; the date may be
    unknown. Ratings exist in the schema but nothing writes them before P5."""

    __tablename__ = "viewings"
    __table_args__ = (
        UniqueConstraint("user_id", "movie_id"),
        CheckConstraint(
            "source IN ('recommendation', 'manual', 'already_watched')", name="source_values"
        ),
        CheckConstraint(
            "rating IS NULL OR rating BETWEEN 1 AND 5",
            name="rating_values",
        ),
        CheckConstraint("version > 0", name="version_positive"),
        CheckConstraint(
            "watched_at IS NULL OR watched_at <= recorded_at", name="watched_not_after_recorded"
        ),
        Index(
            "ix_viewings_user_id_recent",
            "user_id",
            text("COALESCE(watched_at, recorded_at) DESC"),
            "id",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("cineme.users.id", ondelete="CASCADE")
    )
    movie_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("cineme.movies.tmdb_id", ondelete="RESTRICT")
    )
    watched_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    source: Mapped[str] = mapped_column(Text)
    rating: Mapped[int | None] = mapped_column(SmallInteger)
    genre_ids_snapshot: Mapped[list[int]] = mapped_column(
        ARRAY(Integer), server_default=text("'{}'::integer[]")
    )
    recommendation_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("cineme.recommendations.id", ondelete="SET NULL")
    )
    version: Mapped[int] = mapped_column(Integer, server_default=text("1"))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
