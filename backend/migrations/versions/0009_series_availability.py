"""Cached regional watch providers for series (display only).

Revision ID: 0009
Revises: 0008

Same shape and 24 hour freshness as the film cache (ADR 007): JustWatch data
via TMDB, fetched by the backend only. Never enters ranking.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0009"
down_revision: str | None = "0008"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

SCHEMA = "cineme"


def upgrade() -> None:
    op.add_column(
        "series", sa.Column("watch_providers", postgresql.JSONB(), nullable=True), schema=SCHEMA
    )
    op.add_column(
        "series",
        sa.Column("watch_providers_fetched_at", sa.DateTime(timezone=True), nullable=True),
        schema=SCHEMA,
    )


def downgrade() -> None:
    op.drop_column("series", "watch_providers_fetched_at", schema=SCHEMA)
    op.drop_column("series", "watch_providers", schema=SCHEMA)
