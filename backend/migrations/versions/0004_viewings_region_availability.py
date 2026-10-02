"""P4 polish (ADR 006/007): minimal viewings for "Already watched", the
user's streaming region and a per-film watch-provider cache.

viewings follows DATA_MODEL exactly; only the already_watched path writes it
before P5. users.country_code is null until the user chooses a region (the
service derives one from the timezone). movies gains a JSONB cache of
JustWatch availability via TMDB with its own fetch time.

Revision ID: 0004
Revises: 0003
Create Date: 2026-10-02
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0004"
down_revision: str | None = "0003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

SCHEMA = "cineme"
UUID = postgresql.UUID(as_uuid=True)


def upgrade() -> None:
    op.create_table(
        "viewings",
        sa.Column("id", UUID, nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("movie_id", sa.BigInteger(), nullable=False),
        sa.Column("watched_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("recorded_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("source", sa.Text(), nullable=False),
        sa.Column("rating", sa.Text(), nullable=True),
        sa.Column(
            "genre_ids_snapshot",
            postgresql.ARRAY(sa.Integer()),
            server_default=sa.text("'{}'::integer[]"),
            nullable=False,
        ),
        sa.Column("recommendation_id", UUID, nullable=True),
        sa.Column("version", sa.Integer(), server_default=sa.text("1"), nullable=False),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.CheckConstraint(
            "source IN ('recommendation', 'manual', 'already_watched')",
            name=op.f("ck_viewings_source_values"),
        ),
        sa.CheckConstraint(
            "rating IS NULL OR rating IN ('loved', 'liked', 'okay', 'disliked')",
            name=op.f("ck_viewings_rating_values"),
        ),
        sa.CheckConstraint("version > 0", name=op.f("ck_viewings_version_positive")),
        sa.CheckConstraint(
            "watched_at IS NULL OR watched_at <= recorded_at",
            name=op.f("ck_viewings_watched_not_after_recorded"),
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            [f"{SCHEMA}.users.id"],
            name=op.f("fk_viewings_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["movie_id"],
            [f"{SCHEMA}.movies.tmdb_id"],
            name=op.f("fk_viewings_movie_id_movies"),
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["recommendation_id"],
            [f"{SCHEMA}.recommendations.id"],
            name=op.f("fk_viewings_recommendation_id_recommendations"),
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_viewings")),
        sa.UniqueConstraint("user_id", "movie_id", name=op.f("uq_viewings_user_id_movie_id")),
        schema=SCHEMA,
    )
    op.create_index(
        "ix_viewings_user_id_recent",
        "viewings",
        ["user_id", sa.text("COALESCE(watched_at, recorded_at) DESC"), "id"],
        schema=SCHEMA,
    )
    op.add_column("users", sa.Column("country_code", sa.String(2), nullable=True), schema=SCHEMA)
    op.create_check_constraint(
        op.f("ck_users_country_code_format"),
        "users",
        "country_code IS NULL OR country_code ~ '^[A-Z]{2}$'",
        schema=SCHEMA,
    )
    op.add_column(
        "movies", sa.Column("watch_providers", postgresql.JSONB(), nullable=True), schema=SCHEMA
    )
    op.add_column(
        "movies",
        sa.Column("watch_providers_fetched_at", sa.DateTime(timezone=True), nullable=True),
        schema=SCHEMA,
    )


def downgrade() -> None:
    op.drop_column("movies", "watch_providers_fetched_at", schema=SCHEMA)
    op.drop_column("movies", "watch_providers", schema=SCHEMA)
    op.drop_constraint(op.f("ck_users_country_code_format"), "users", schema=SCHEMA, type_="check")
    op.drop_column("users", "country_code", schema=SCHEMA)
    op.drop_index("ix_viewings_user_id_recent", table_name="viewings", schema=SCHEMA)
    op.drop_table("viewings", schema=SCHEMA)
