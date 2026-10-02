"""P4: daily recommendation sessions, recommendation attempts and temporary
rejection feedback.

DATA_MODEL "Additive migration schedule": P4 adds recommendation_sessions and
recommendations with bounded JSON evidence (no candidate-score table).
rejection_feedback is brought forward from P5 by ADR 006 for the temporary
reasons; viewings and movie_blocks stay in P5.

Revision ID: 0003
Revises: 0002
Create Date: 2026-10-02
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0003"
down_revision: str | None = "0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

SCHEMA = "cineme"
UUID = postgresql.UUID(as_uuid=True)
JSONB = postgresql.JSONB()


def _timestamps() -> list[sa.Column]:  # type: ignore[type-arg]
    return [
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    ]


def upgrade() -> None:
    op.create_table(
        "recommendation_sessions",
        sa.Column("id", UUID, nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("local_date", sa.Date(), nullable=False),
        sa.Column("timezone_snapshot", sa.String(64), nullable=False),
        sa.Column("day_ends_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("context", JSONB, nullable=False),
        sa.Column("version", sa.Integer(), server_default=sa.text("1"), nullable=False),
        sa.Column("current_recommendation_id", UUID, nullable=True),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        *_timestamps(),
        sa.CheckConstraint("version > 0", name=op.f("ck_recommendation_sessions_version_positive")),
        sa.CheckConstraint(
            "jsonb_typeof(context) = 'object'",
            name=op.f("ck_recommendation_sessions_context_object"),
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            [f"{SCHEMA}.users.id"],
            name=op.f("fk_recommendation_sessions_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_recommendation_sessions")),
        sa.UniqueConstraint(
            "user_id", "local_date", name=op.f("uq_recommendation_sessions_user_id_local_date")
        ),
        schema=SCHEMA,
    )
    op.create_index(
        "ix_recommendation_sessions_user_id_created_at",
        "recommendation_sessions",
        ["user_id", sa.text("created_at DESC")],
        schema=SCHEMA,
    )

    op.create_table(
        "recommendations",
        sa.Column("id", UUID, nullable=False),
        sa.Column("session_id", UUID, nullable=False),
        sa.Column("movie_id", sa.BigInteger(), nullable=True),
        sa.Column("status", sa.Text(), nullable=False),
        sa.Column("total_score", sa.Numeric(12, 6), nullable=True),
        sa.Column("engine_version", sa.Text(), nullable=False),
        sa.Column("config_version", sa.Text(), nullable=False),
        sa.Column("config_hash", sa.String(64), nullable=False),
        sa.Column("config_snapshot", JSONB, nullable=False),
        sa.Column("context_snapshot", JSONB, nullable=False),
        sa.Column("winner_snapshot", JSONB, nullable=True),
        sa.Column("top_candidates", JSONB, server_default=sa.text("'[]'::jsonb"), nullable=False),
        sa.Column("exclusion_summary", JSONB, nullable=False),
        sa.Column(
            "comparisons_truncated", sa.Boolean(), server_default=sa.text("false"), nullable=False
        ),
        sa.Column("reason_data", JSONB, nullable=False),
        sa.Column("explanation", sa.Text(), nullable=False),
        sa.Column("no_match_summary", JSONB, nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("accepted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("resolved_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "status IN ('offered','accepted','rejected','watched','superseded','no_match')",
            name=op.f("ck_recommendations_status_values"),
        ),
        sa.CheckConstraint(
            "(status = 'no_match') = (movie_id IS NULL)"
            " AND (movie_id IS NULL) = (total_score IS NULL)"
            " AND (movie_id IS NULL) = (winner_snapshot IS NULL)",
            name=op.f("ck_recommendations_selected_has_movie_score_winner"),
        ),
        sa.CheckConstraint(
            "total_score IS NULL OR total_score BETWEEN 0 AND 100",
            name=op.f("ck_recommendations_score_range"),
        ),
        sa.CheckConstraint(
            "char_length(config_hash) = 64", name=op.f("ck_recommendations_config_hash_sha256")
        ),
        sa.CheckConstraint(
            "jsonb_typeof(top_candidates) = 'array' AND jsonb_array_length(top_candidates) <= 9",
            name=op.f("ck_recommendations_top_candidates_bounded"),
        ),
        sa.CheckConstraint(
            "status <> 'no_match' OR jsonb_array_length(top_candidates) = 0",
            name=op.f("ck_recommendations_no_match_has_no_comparisons"),
        ),
        sa.CheckConstraint(
            "(status IN ('offered','accepted')) = (resolved_at IS NULL)",
            name=op.f("ck_recommendations_resolved_when_terminal"),
        ),
        sa.CheckConstraint(
            "status <> 'accepted' OR accepted_at IS NOT NULL",
            name=op.f("ck_recommendations_accepted_at_set"),
        ),
        sa.ForeignKeyConstraint(
            ["session_id"],
            [f"{SCHEMA}.recommendation_sessions.id"],
            name=op.f("fk_recommendations_session_id_recommendation_sessions"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["movie_id"],
            [f"{SCHEMA}.movies.tmdb_id"],
            name=op.f("fk_recommendations_movie_id_movies"),
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_recommendations")),
        schema=SCHEMA,
    )
    op.create_index(
        "uq_recommendations_one_unresolved_per_session",
        "recommendations",
        ["session_id"],
        unique=True,
        postgresql_where=sa.text("status IN ('offered','accepted')"),
        schema=SCHEMA,
    )
    op.create_index(
        "ix_recommendations_session_id_created_at_id",
        "recommendations",
        ["session_id", sa.text("created_at DESC"), "id"],
        schema=SCHEMA,
    )
    op.create_index(
        "ix_recommendations_movie_id_created_at",
        "recommendations",
        ["movie_id", sa.text("created_at DESC")],
        schema=SCHEMA,
    )
    # Circular pointer, added after both tables and checked at commit.
    op.create_foreign_key(
        "fk_sessions_current_recommendation",
        "recommendation_sessions",
        "recommendations",
        ["current_recommendation_id"],
        ["id"],
        source_schema=SCHEMA,
        referent_schema=SCHEMA,
        ondelete="SET NULL",
        deferrable=True,
        initially="DEFERRED",
    )

    op.create_table(
        "rejection_feedback",
        sa.Column("id", UUID, nullable=False),
        sa.Column("recommendation_id", UUID, nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("details", JSONB, server_default=sa.text("'{}'::jsonb"), nullable=False),
        sa.Column("note", sa.String(500), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "reason IN ('not_tonight','too_long','wrong_genre','too_serious','want_lighter',"
            "'already_watched','never_recommend','other')",
            name=op.f("ck_rejection_feedback_reason_values"),
        ),
        sa.CheckConstraint(
            "jsonb_typeof(details) = 'object'", name=op.f("ck_rejection_feedback_details_object")
        ),
        sa.ForeignKeyConstraint(
            ["recommendation_id"],
            [f"{SCHEMA}.recommendations.id"],
            name=op.f("fk_rejection_feedback_recommendation_id_recommendations"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_rejection_feedback")),
        sa.UniqueConstraint(
            "recommendation_id", name=op.f("uq_rejection_feedback_recommendation_id")
        ),
        schema=SCHEMA,
    )


def downgrade() -> None:
    op.drop_table("rejection_feedback", schema=SCHEMA)
    op.drop_constraint(
        "fk_sessions_current_recommendation",
        "recommendation_sessions",
        schema=SCHEMA,
        type_="foreignkey",
    )
    op.drop_table("recommendations", schema=SCHEMA)
    op.drop_table("recommendation_sessions", schema=SCHEMA)
