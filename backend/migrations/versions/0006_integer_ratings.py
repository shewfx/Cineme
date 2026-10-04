"""Convert legacy viewing categories to five-star integer ratings.

Revision ID: 0006
Revises: 0005
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0006"
down_revision: str | None = "0005"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

SCHEMA = "cineme"


def upgrade() -> None:
    op.drop_constraint("ck_viewings_rating_values", "viewings", schema=SCHEMA)
    op.alter_column(
        "viewings",
        "rating",
        schema=SCHEMA,
        existing_type=sa.Text(),
        type_=sa.SmallInteger(),
        postgresql_using=(
            "CASE rating WHEN 'disliked' THEN 1 WHEN 'okay' THEN 3 "
            "WHEN 'liked' THEN 4 WHEN 'loved' THEN 5 ELSE NULL END"
        ),
    )
    op.create_check_constraint(
        op.f("ck_viewings_rating_values"),
        "viewings",
        "rating IS NULL OR rating BETWEEN 1 AND 5",
        schema=SCHEMA,
    )


def downgrade() -> None:
    op.drop_constraint("ck_viewings_rating_values", "viewings", schema=SCHEMA)
    op.alter_column(
        "viewings",
        "rating",
        schema=SCHEMA,
        existing_type=sa.SmallInteger(),
        type_=sa.Text(),
        postgresql_using=(
            "CASE rating WHEN 1 THEN 'disliked' WHEN 2 THEN 'disliked' "
            "WHEN 3 THEN 'okay' WHEN 4 THEN 'liked' WHEN 5 THEN 'loved' ELSE NULL END"
        ),
    )
    op.create_check_constraint(
        op.f("ck_viewings_rating_values"),
        "viewings",
        "rating IS NULL OR rating IN ('loved', 'liked', 'okay', 'disliked')",
        schema=SCHEMA,
    )
