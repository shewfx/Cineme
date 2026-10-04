"""P5: persistent movie blocks and accepted-pick follow-up state.

Revision ID: 0005
Revises: 0004
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0005"
down_revision: str | None = "0004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

SCHEMA = "cineme"


def upgrade() -> None:
    op.create_table(
        "movie_blocks",
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("movie_id", sa.BigInteger(), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column("reason", sa.Text(), server_default=sa.text("'never_recommend'"), nullable=False),
        sa.CheckConstraint("reason = 'never_recommend'", name="ck_movie_blocks_reason"),
        sa.ForeignKeyConstraint(["user_id"], ["cineme.users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["movie_id"], ["cineme.movies.tmdb_id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("user_id", "movie_id"),
        schema=SCHEMA,
    )
    op.add_column(
        "recommendations",
        sa.Column("follow_up_prompted_on", sa.Date(), nullable=True),
        schema=SCHEMA,
    )
    op.add_column(
        "recommendations",
        sa.Column(
            "follow_up_resolved", sa.Boolean(), server_default=sa.text("false"), nullable=False
        ),
        schema=SCHEMA,
    )
    op.create_index(
        "ix_recommendations_follow_up",
        "recommendations",
        ["status", "accepted_at"],
        schema=SCHEMA,
        postgresql_where=sa.text("status = 'accepted' AND follow_up_resolved = false"),
    )


def downgrade() -> None:
    op.drop_index("ix_recommendations_follow_up", table_name="recommendations", schema=SCHEMA)
    op.drop_column("recommendations", "follow_up_resolved", schema=SCHEMA)
    op.drop_column("recommendations", "follow_up_prompted_on", schema=SCHEMA)
    op.drop_table("movie_blocks", schema=SCHEMA)
