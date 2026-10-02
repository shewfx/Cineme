import uuid
from datetime import datetime

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    String,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class WatchlistEntry(Base):
    """`watchlist_entries` (DATA_MODEL): a user's inventory, never a taste
    signal. One row per (user, movie), archived on removal and restored on
    re-add, so history is never lost."""

    __tablename__ = "watchlist_entries"
    __table_args__ = (
        UniqueConstraint("user_id", "movie_id"),
        CheckConstraint("status IN ('active', 'removed')", name="status_values"),
        CheckConstraint(
            "(status = 'removed') = (removed_at IS NOT NULL)", name="removed_at_matches_status"
        ),
        CheckConstraint("source_type IN ('manual')", name="source_type_values"),
        Index(
            "ix_watchlist_entries_user_id_status_added_at_id",
            "user_id",
            "status",
            text("added_at DESC"),
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
    status: Mapped[str] = mapped_column(Text, server_default=text("'active'"))
    added_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    removed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    source_type: Mapped[str] = mapped_column(Text, server_default=text("'manual'"))
    source_ref: Mapped[str | None] = mapped_column(String(256))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
