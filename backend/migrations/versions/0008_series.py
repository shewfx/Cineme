"""Shows and anime: series metadata, per-user entries, episode history, blocks,
the Tonight media preference and episode recommendations (ADR 011).

Revision ID: 0008
Revises: 0007

Additive: movie tables keep their meaning. `recommendations` gains an episode
identity (series + season + episode) beside `movie_id`; the old rows satisfy
the replaced checks, so a deployed older backend keeps working after this
migration. `user_preferences.tonight_media` defaults to 'movies' for every
existing row.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0008"
down_revision: str | None = "0007"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

SCHEMA = "cineme"
_NOW = sa.func.now()


def _ts(name: str, **kw: object) -> sa.Column:  # type: ignore[type-arg]
    return sa.Column(name, sa.DateTime(timezone=True), **kw)  # type: ignore[arg-type]


def upgrade() -> None:
    op.create_table(
        "series",
        sa.Column("tmdb_id", sa.BigInteger(), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("original_name", sa.Text()),
        sa.Column("first_air_date", sa.Date()),
        sa.Column("last_air_date", sa.Date()),
        sa.Column("status", sa.Text()),
        sa.Column(
            "genre_ids",
            postgresql.ARRAY(sa.Integer()),
            server_default=sa.text("'{}'::integer[]"),
            nullable=False,
        ),
        sa.Column("overview", sa.Text()),
        sa.Column("poster_path", sa.Text()),
        sa.Column("original_language", sa.String(8)),
        sa.Column(
            "origin_countries",
            postgresql.ARRAY(sa.Text()),
            server_default=sa.text("'{}'::text[]"),
            nullable=False,
        ),
        sa.Column("adult", sa.Boolean(), nullable=False),
        sa.Column("vote_average", sa.Numeric(4, 2)),
        sa.Column("vote_count", sa.Integer()),
        sa.Column("metadata_status", sa.Text(), server_default=sa.text("'ready'"), nullable=False),
        _ts("fetched_at", nullable=False),
        _ts("episodes_fetched_at"),
        _ts("created_at", server_default=_NOW, nullable=False),
        _ts("updated_at", server_default=_NOW, nullable=False),
        sa.PrimaryKeyConstraint("tmdb_id"),
        sa.CheckConstraint("tmdb_id > 0", name=op.f("ck_series_tmdb_id_positive")),
        sa.CheckConstraint(
            "vote_average IS NULL OR vote_average BETWEEN 0 AND 10",
            name=op.f("ck_series_vote_average_range"),
        ),
        sa.CheckConstraint(
            "vote_count IS NULL OR vote_count >= 0", name=op.f("ck_series_vote_count_nonnegative")
        ),
        sa.CheckConstraint(
            "metadata_status IN ('ready', 'unavailable')",
            name=op.f("ck_series_metadata_status_values"),
        ),
        sa.CheckConstraint(
            "poster_path IS NULL OR poster_path ~ '^/[A-Za-z0-9_-]+\\.(jpg|jpeg|png|webp)$'",
            name=op.f("ck_series_poster_path_relative"),
        ),
        sa.CheckConstraint("char_length(btrim(name)) > 0", name=op.f("ck_series_name_not_blank")),
        schema=SCHEMA,
    )

    op.create_table(
        "series_episodes",
        sa.Column("series_id", sa.BigInteger(), nullable=False),
        sa.Column("season_number", sa.SmallInteger(), nullable=False),
        sa.Column("episode_number", sa.SmallInteger(), nullable=False),
        sa.Column("tmdb_episode_id", sa.BigInteger()),
        sa.Column("name", sa.Text()),
        sa.Column("air_date", sa.Date()),
        sa.Column("runtime_minutes", sa.SmallInteger()),
        _ts("fetched_at", nullable=False),
        sa.PrimaryKeyConstraint("series_id", "season_number", "episode_number"),
        sa.ForeignKeyConstraint(
            ["series_id"],
            [f"{SCHEMA}.series.tmdb_id"],
            ondelete="CASCADE",
            name=op.f("fk_series_episodes_series_id_series"),
        ),
        sa.CheckConstraint(
            "season_number >= 1 AND episode_number >= 1",
            name=op.f("ck_series_episodes_regular_numbers"),
        ),
        sa.CheckConstraint(
            "runtime_minutes IS NULL OR runtime_minutes BETWEEN 1 AND 600",
            name=op.f("ck_series_episodes_runtime_range"),
        ),
        schema=SCHEMA,
    )

    op.create_table(
        "series_entries",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("series_id", sa.BigInteger(), nullable=False),
        sa.Column("status", sa.Text(), server_default=sa.text("'active'"), nullable=False),
        _ts("added_at", nullable=False),
        _ts("removed_at"),
        sa.Column("source_type", sa.Text(), server_default=sa.text("'manual'"), nullable=False),
        sa.Column("progress_season", sa.SmallInteger()),
        sa.Column("progress_episode", sa.SmallInteger()),
        sa.Column("progress_version", sa.Integer(), server_default=sa.text("1"), nullable=False),
        _ts("progress_updated_at"),
        sa.Column("series_rating", sa.SmallInteger()),
        _ts("created_at", server_default=_NOW, nullable=False),
        _ts("updated_at", server_default=_NOW, nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.ForeignKeyConstraint(
            ["user_id"],
            [f"{SCHEMA}.users.id"],
            ondelete="CASCADE",
            name=op.f("fk_series_entries_user_id_users"),
        ),
        sa.ForeignKeyConstraint(
            ["series_id"],
            [f"{SCHEMA}.series.tmdb_id"],
            ondelete="RESTRICT",
            name=op.f("fk_series_entries_series_id_series"),
        ),
        sa.UniqueConstraint("user_id", "series_id", name=op.f("uq_series_entries_user_id")),
        sa.CheckConstraint(
            "status IN ('active', 'removed')", name=op.f("ck_series_entries_status_values")
        ),
        sa.CheckConstraint(
            "(status = 'removed') = (removed_at IS NOT NULL)",
            name=op.f("ck_series_entries_removed_at_matches_status"),
        ),
        sa.CheckConstraint(
            "(progress_season IS NULL) = (progress_episode IS NULL)"
            " AND (progress_season IS NULL OR (progress_season >= 1 AND progress_episode >= 1))",
            name=op.f("ck_series_entries_progress_pair"),
        ),
        sa.CheckConstraint("progress_version > 0", name=op.f("ck_series_entries_version_positive")),
        sa.CheckConstraint(
            "series_rating IS NULL OR series_rating BETWEEN 1 AND 5",
            name=op.f("ck_series_entries_rating_range"),
        ),
        schema=SCHEMA,
    )
    op.create_index(
        "ix_series_entries_user_id_status_added_at_id",
        "series_entries",
        ["user_id", "status", "added_at", "id"],
        schema=SCHEMA,
    )

    op.create_table(
        "episode_viewings",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("series_id", sa.BigInteger(), nullable=False),
        sa.Column("season_number", sa.SmallInteger(), nullable=False),
        sa.Column("episode_number", sa.SmallInteger(), nullable=False),
        _ts("watched_at"),
        _ts("recorded_at", nullable=False),
        sa.Column("source", sa.Text(), nullable=False),
        sa.Column("recommendation_id", postgresql.UUID(as_uuid=True)),
        sa.Column("rating", sa.SmallInteger()),
        sa.Column("version", sa.Integer(), server_default=sa.text("1"), nullable=False),
        sa.Column(
            "genre_ids_snapshot",
            postgresql.ARRAY(sa.Integer()),
            server_default=sa.text("'{}'::integer[]"),
            nullable=False,
        ),
        sa.Column("episode_name_snapshot", sa.Text()),
        _ts("updated_at", server_default=_NOW, nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.ForeignKeyConstraint(
            ["user_id"],
            [f"{SCHEMA}.users.id"],
            ondelete="CASCADE",
            name=op.f("fk_episode_viewings_user_id_users"),
        ),
        sa.ForeignKeyConstraint(
            ["series_id"],
            [f"{SCHEMA}.series.tmdb_id"],
            ondelete="RESTRICT",
            name=op.f("fk_episode_viewings_series_id_series"),
        ),
        sa.ForeignKeyConstraint(
            ["recommendation_id"],
            [f"{SCHEMA}.recommendations.id"],
            ondelete="SET NULL",
            name=op.f("fk_episode_viewings_recommendation_id_recommendations"),
        ),
        sa.UniqueConstraint(
            "user_id",
            "series_id",
            "season_number",
            "episode_number",
            name=op.f("uq_episode_viewings_user_id"),
        ),
        sa.CheckConstraint(
            "season_number >= 1 AND episode_number >= 1",
            name=op.f("ck_episode_viewings_regular_numbers"),
        ),
        sa.CheckConstraint(
            "source IN ('recommendation', 'manual', 'follow_up')",
            name=op.f("ck_episode_viewings_source_values"),
        ),
        sa.CheckConstraint(
            "rating IS NULL OR rating BETWEEN 1 AND 5",
            name=op.f("ck_episode_viewings_rating_range"),
        ),
        sa.CheckConstraint("version > 0", name=op.f("ck_episode_viewings_version_positive")),
        schema=SCHEMA,
    )
    op.create_index(
        "ix_episode_viewings_user_id_recorded_at",
        "episode_viewings",
        ["user_id", sa.text("recorded_at DESC")],
        schema=SCHEMA,
    )

    op.create_table(
        "series_blocks",
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("series_id", sa.BigInteger(), nullable=False),
        _ts("created_at", server_default=_NOW, nullable=False),
        sa.Column("reason", sa.Text(), server_default=sa.text("'never_recommend'"), nullable=False),
        sa.PrimaryKeyConstraint("user_id", "series_id"),
        sa.ForeignKeyConstraint(
            ["user_id"],
            [f"{SCHEMA}.users.id"],
            ondelete="CASCADE",
            name=op.f("fk_series_blocks_user_id_users"),
        ),
        sa.ForeignKeyConstraint(
            ["series_id"],
            [f"{SCHEMA}.series.tmdb_id"],
            ondelete="RESTRICT",
            name=op.f("fk_series_blocks_series_id_series"),
        ),
        sa.CheckConstraint("reason = 'never_recommend'", name=op.f("ck_series_blocks_reason")),
        schema=SCHEMA,
    )

    op.add_column(
        "user_preferences",
        sa.Column("tonight_media", sa.Text(), server_default=sa.text("'movies'"), nullable=False),
        schema=SCHEMA,
    )
    op.create_check_constraint(
        op.f("ck_user_preferences_tonight_media_values"),
        "user_preferences",
        "tonight_media IN ('movies', 'movies_and_shows', 'shows')",
        schema=SCHEMA,
    )

    # Episode recommendations share the one-pick-per-session machinery.
    op.add_column(
        "recommendations",
        sa.Column("media_kind", sa.Text(), server_default=sa.text("'movie'"), nullable=False),
        schema=SCHEMA,
    )
    op.add_column("recommendations", sa.Column("series_id", sa.BigInteger()), schema=SCHEMA)
    op.add_column("recommendations", sa.Column("season_number", sa.SmallInteger()), schema=SCHEMA)
    op.add_column("recommendations", sa.Column("episode_number", sa.SmallInteger()), schema=SCHEMA)
    op.create_foreign_key(
        op.f("fk_recommendations_series_id_series"),
        "recommendations",
        "series",
        ["series_id"],
        ["tmdb_id"],
        source_schema=SCHEMA,
        referent_schema=SCHEMA,
        ondelete="RESTRICT",
    )
    op.drop_constraint(
        "ck_recommendations_selected_has_movie_score_winner", "recommendations", schema=SCHEMA
    )
    op.drop_constraint("ck_recommendations_score_range", "recommendations", schema=SCHEMA)
    identity = "(movie_id IS NULL AND series_id IS NULL)"
    op.create_check_constraint(
        op.f("ck_recommendations_selected_has_movie_score_winner"),
        "recommendations",
        f"(status = 'no_match') = {identity}"
        " AND NOT (movie_id IS NOT NULL AND series_id IS NOT NULL)"
        f" AND {identity} = (total_score IS NULL)"
        f" AND {identity} = (winner_snapshot IS NULL)",
        schema=SCHEMA,
    )
    op.create_check_constraint(
        op.f("ck_recommendations_episode_identity"),
        "recommendations",
        "(media_kind IN ('movie', 'episode'))"
        " AND ((series_id IS NULL) = (season_number IS NULL))"
        " AND ((series_id IS NULL) = (episode_number IS NULL))"
        " AND ((media_kind = 'episode') = (series_id IS NOT NULL))",
        schema=SCHEMA,
    )
    # Episode scores add a bounded continuity bonus on top of 100 points.
    op.create_check_constraint(
        op.f("ck_recommendations_score_range"),
        "recommendations",
        "total_score IS NULL OR total_score BETWEEN 0 AND 120",
        schema=SCHEMA,
    )
    op.create_index(
        "ix_recommendations_series_episode_created_at",
        "recommendations",
        ["series_id", "season_number", "episode_number", sa.text("created_at DESC")],
        schema=SCHEMA,
        postgresql_where=sa.text("series_id IS NOT NULL"),
    )


def downgrade() -> None:
    op.drop_index("ix_recommendations_series_episode_created_at", "recommendations", schema=SCHEMA)
    op.execute(f"DELETE FROM {SCHEMA}.recommendations WHERE series_id IS NOT NULL")  # noqa: S608
    op.drop_constraint("ck_recommendations_score_range", "recommendations", schema=SCHEMA)
    op.drop_constraint("ck_recommendations_episode_identity", "recommendations", schema=SCHEMA)
    op.drop_constraint(
        "ck_recommendations_selected_has_movie_score_winner", "recommendations", schema=SCHEMA
    )
    op.drop_constraint("fk_recommendations_series_id_series", "recommendations", schema=SCHEMA)
    for column in ("episode_number", "season_number", "series_id", "media_kind"):
        op.drop_column("recommendations", column, schema=SCHEMA)
    op.create_check_constraint(
        op.f("ck_recommendations_selected_has_movie_score_winner"),
        "recommendations",
        "(status = 'no_match') = (movie_id IS NULL)"
        " AND (movie_id IS NULL) = (total_score IS NULL)"
        " AND (movie_id IS NULL) = (winner_snapshot IS NULL)",
        schema=SCHEMA,
    )
    op.create_check_constraint(
        op.f("ck_recommendations_score_range"),
        "recommendations",
        "total_score IS NULL OR total_score BETWEEN 0 AND 100",
        schema=SCHEMA,
    )
    op.drop_constraint(
        "ck_user_preferences_tonight_media_values", "user_preferences", schema=SCHEMA
    )
    op.drop_column("user_preferences", "tonight_media", schema=SCHEMA)
    op.drop_table("series_blocks", schema=SCHEMA)
    op.drop_index("ix_episode_viewings_user_id_recorded_at", "episode_viewings", schema=SCHEMA)
    op.drop_table("episode_viewings", schema=SCHEMA)
    op.drop_index("ix_series_entries_user_id_status_added_at_id", "series_entries", schema=SCHEMA)
    op.drop_table("series_entries", schema=SCHEMA)
    op.drop_table("series_episodes", schema=SCHEMA)
    op.drop_table("series", schema=SCHEMA)
