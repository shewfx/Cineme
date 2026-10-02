import uuid
from datetime import date, datetime
from decimal import Decimal
from typing import Any

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class RecommendationSession(Base):
    """`recommendation_sessions` (DATA_MODEL): one per user and local date.
    No state enum; Today's state derives from the pointer and attempts."""

    __tablename__ = "recommendation_sessions"
    __table_args__ = (
        UniqueConstraint("user_id", "local_date"),
        CheckConstraint("version > 0", name="version_positive"),
        CheckConstraint("jsonb_typeof(context) = 'object'", name="context_object"),
        Index("ix_recommendation_sessions_user_id_created_at", "user_id", text("created_at DESC")),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("cineme.users.id", ondelete="CASCADE")
    )
    local_date: Mapped[date] = mapped_column(Date)
    timezone_snapshot: Mapped[str] = mapped_column(String(64))
    day_ends_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    context: Mapped[dict[str, Any]] = mapped_column(JSONB)
    version: Mapped[int] = mapped_column(Integer, server_default=text("1"))
    current_recommendation_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey(
            "cineme.recommendations.id",
            name="fk_sessions_current_recommendation",
            ondelete="SET NULL",
            use_alter=True,
            deferrable=True,
            initially="DEFERRED",
        ),
    )
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


STATUSES = ("offered", "accepted", "rejected", "watched", "superseded", "no_match")


class Recommendation(Base):
    """`recommendations`: one row per selection attempt, including no-match.
    Bounded evidence only: winner, config, context, exclusion counts and at
    most nine runners-up."""

    __tablename__ = "recommendations"
    __table_args__ = (
        CheckConstraint(
            "status IN ('offered','accepted','rejected','watched','superseded','no_match')",
            name="status_values",
        ),
        CheckConstraint(
            "(status = 'no_match') = (movie_id IS NULL)"
            " AND (movie_id IS NULL) = (total_score IS NULL)"
            " AND (movie_id IS NULL) = (winner_snapshot IS NULL)",
            name="selected_has_movie_score_winner",
        ),
        CheckConstraint("total_score IS NULL OR total_score BETWEEN 0 AND 100", name="score_range"),
        CheckConstraint("char_length(config_hash) = 64", name="config_hash_sha256"),
        CheckConstraint(
            "jsonb_typeof(top_candidates) = 'array' AND jsonb_array_length(top_candidates) <= 9",
            name="top_candidates_bounded",
        ),
        CheckConstraint(
            "status <> 'no_match' OR jsonb_array_length(top_candidates) = 0",
            name="no_match_has_no_comparisons",
        ),
        CheckConstraint(
            "(status IN ('offered','accepted')) = (resolved_at IS NULL)",
            name="resolved_when_terminal",
        ),
        CheckConstraint("status <> 'accepted' OR accepted_at IS NOT NULL", name="accepted_at_set"),
        Index(
            "uq_recommendations_one_unresolved_per_session",
            "session_id",
            unique=True,
            postgresql_where=text("status IN ('offered','accepted')"),
        ),
        Index(
            "ix_recommendations_session_id_created_at_id",
            "session_id",
            text("created_at DESC"),
            "id",
        ),
        Index("ix_recommendations_movie_id_created_at", "movie_id", text("created_at DESC")),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    session_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("cineme.recommendation_sessions.id", ondelete="CASCADE")
    )
    movie_id: Mapped[int | None] = mapped_column(
        BigInteger, ForeignKey("cineme.movies.tmdb_id", ondelete="RESTRICT")
    )
    status: Mapped[str] = mapped_column(Text)
    total_score: Mapped[Decimal | None] = mapped_column(Numeric(12, 6))
    engine_version: Mapped[str] = mapped_column(Text)
    config_version: Mapped[str] = mapped_column(Text)
    config_hash: Mapped[str] = mapped_column(String(64))
    config_snapshot: Mapped[dict[str, Any]] = mapped_column(JSONB)
    context_snapshot: Mapped[dict[str, Any]] = mapped_column(JSONB)
    winner_snapshot: Mapped[dict[str, Any] | None] = mapped_column(JSONB)
    top_candidates: Mapped[list[Any]] = mapped_column(JSONB, server_default=text("'[]'::jsonb"))
    exclusion_summary: Mapped[dict[str, Any]] = mapped_column(JSONB)
    comparisons_truncated: Mapped[bool] = mapped_column(server_default=text("false"))
    reason_data: Mapped[dict[str, Any]] = mapped_column(JSONB)
    explanation: Mapped[str] = mapped_column(Text)
    no_match_summary: Mapped[dict[str, Any] | None] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    accepted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class RejectionFeedback(Base):
    """`rejection_feedback`, brought forward from P5 by ADR 006 for the
    temporary reasons only. Owner derives through the recommendation."""

    __tablename__ = "rejection_feedback"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    recommendation_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("cineme.recommendations.id", ondelete="CASCADE"),
        unique=True,
    )
    reason: Mapped[str] = mapped_column(Text)
    details: Mapped[dict[str, Any]] = mapped_column(JSONB, server_default=text("'{}'::jsonb"))
    note: Mapped[str | None] = mapped_column(String(500))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))

    __table_args__ = (
        CheckConstraint(
            "reason IN ('not_tonight','too_long','wrong_genre','too_serious','want_lighter',"
            "'already_watched','never_recommend','other')",
            name="reason_values",
        ),
        CheckConstraint("jsonb_typeof(details) = 'object'", name="details_object"),
    )
