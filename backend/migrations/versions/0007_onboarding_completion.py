"""Server-owned onboarding completion for new accounts.

Revision ID: 0007
Revises: 0006

`users.onboarding_completed_at` is NULL while a new account still needs
onboarding. Every account that exists when this migration runs is backfilled
(to its creation time) so no current user is sent through onboarding.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0007"
down_revision: str | None = "0006"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

SCHEMA = "cineme"


def upgrade() -> None:
    op.add_column(
        "users",
        sa.Column("onboarding_completed_at", sa.DateTime(timezone=True), nullable=True),
        schema=SCHEMA,
    )
    op.execute(
        f"UPDATE {SCHEMA}.users SET onboarding_completed_at = created_at"  # noqa: S608
    )


def downgrade() -> None:
    op.drop_column("users", "onboarding_completed_at", schema=SCHEMA)
