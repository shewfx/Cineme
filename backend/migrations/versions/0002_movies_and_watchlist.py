"""P3: shared movies metadata cache and per-user watchlist entries.

DATA_MODEL "Additive migration schedule": P3 adds movies and
watchlist_entries; idempotency_records already exists (ADR 003).

Revision ID: 0002
Revises: 0001
Create Date: 2026-10-02
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0002"
down_revision: str | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

SCHEMA = "cineme"


def upgrade() -> None:
    op.create_table(
        "movies",
        sa.Column("tmdb_id", sa.BigInteger(), autoincrement=False, nullable=False),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("original_title", sa.Text(), nullable=True),
        sa.Column("release_date", sa.Date(), nullable=True),
        sa.Column("runtime_minutes", sa.SmallInteger(), nullable=True),
        sa.Column(
            "genre_ids",
            postgresql.ARRAY(sa.Integer()),
            server_default=sa.text("'{}'::integer[]"),
            nullable=False,
        ),
        sa.Column("overview", sa.Text(), nullable=True),
        sa.Column("poster_path", sa.Text(), nullable=True),
        sa.Column("original_language", sa.String(8), nullable=True),
        sa.Column("adult", sa.Boolean(), nullable=False),
        sa.Column("vote_average", sa.Numeric(4, 2), nullable=True),
        sa.Column("vote_count", sa.Integer(), nullable=True),
        sa.Column("metadata_status", sa.Text(), server_default=sa.text("'ready'"), nullable=False),
        sa.Column("fetched_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.CheckConstraint("tmdb_id > 0", name=op.f("ck_movies_tmdb_id_positive")),
        sa.CheckConstraint(
            "runtime_minutes IS NULL OR runtime_minutes BETWEEN 1 AND 600",
            name=op.f("ck_movies_runtime_range"),
        ),
        sa.CheckConstraint(
            "vote_average IS NULL OR vote_average BETWEEN 0 AND 10",
            name=op.f("ck_movies_vote_average_range"),
        ),
        sa.CheckConstraint(
            "vote_count IS NULL OR vote_count >= 0", name=op.f("ck_movies_vote_count_nonnegative")
        ),
        sa.CheckConstraint(
            "metadata_status IN ('ready', 'unavailable')",
            name=op.f("ck_movies_metadata_status_values"),
        ),
        sa.CheckConstraint(
            "poster_path IS NULL OR poster_path ~ '^/[A-Za-z0-9_-]+\\.(jpg|jpeg|png|webp)$'",
            name=op.f("ck_movies_poster_path_relative"),
        ),
        sa.CheckConstraint("char_length(btrim(title)) > 0", name=op.f("ck_movies_title_not_blank")),
        sa.PrimaryKeyConstraint("tmdb_id", name=op.f("pk_movies")),
        schema=SCHEMA,
    )

    op.create_table(
        "watchlist_entries",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("movie_id", sa.BigInteger(), nullable=False),
        sa.Column("status", sa.Text(), server_default=sa.text("'active'"), nullable=False),
        sa.Column("added_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("removed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("source_type", sa.Text(), server_default=sa.text("'manual'"), nullable=False),
        sa.Column("source_ref", sa.String(256), nullable=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.CheckConstraint(
            "status IN ('active', 'removed')", name=op.f("ck_watchlist_entries_status_values")
        ),
        sa.CheckConstraint(
            "(status = 'removed') = (removed_at IS NOT NULL)",
            name=op.f("ck_watchlist_entries_removed_at_matches_status"),
        ),
        sa.CheckConstraint(
            "source_type IN ('manual')", name=op.f("ck_watchlist_entries_source_type_values")
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            [f"{SCHEMA}.users.id"],
            name=op.f("fk_watchlist_entries_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["movie_id"],
            [f"{SCHEMA}.movies.tmdb_id"],
            name=op.f("fk_watchlist_entries_movie_id_movies"),
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_watchlist_entries")),
        sa.UniqueConstraint(
            "user_id", "movie_id", name=op.f("uq_watchlist_entries_user_id_movie_id")
        ),
        schema=SCHEMA,
    )
    op.create_index(
        op.f("ix_watchlist_entries_user_id_status_added_at_id"),
        "watchlist_entries",
        ["user_id", "status", sa.text("added_at DESC"), "id"],
        schema=SCHEMA,
    )


def downgrade() -> None:
    op.drop_index(
        op.f("ix_watchlist_entries_user_id_status_added_at_id"),
        table_name="watchlist_entries",
        schema=SCHEMA,
    )
    op.drop_table("watchlist_entries", schema=SCHEMA)
    op.drop_table("movies", schema=SCHEMA)
