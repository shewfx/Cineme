"""P2: cineme schema with users, user_preferences and idempotency_records.

DATA_MODEL "Additive migration schedule": P2 adds users and user_preferences
only; idempotency_records is brought forward from P3 for PATCH /me (ADR 003).
No movie, watchlist, recommendation, viewing or trait tables.

Revision ID: 0001
Revises:
Create Date: 2026-10-02
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

SCHEMA = "cineme"


def upgrade() -> None:
    op.execute(f"CREATE SCHEMA {SCHEMA}")
    # App tables are reached only through FastAPI. Without Supabase roles this
    # just removes PUBLIC access; with them, anon/authenticated get nothing.
    op.execute(f"REVOKE ALL ON SCHEMA {SCHEMA} FROM PUBLIC")
    op.execute(
        """
        DO $$
        DECLARE r text;
        BEGIN
          FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
              EXECUTE format('REVOKE ALL ON SCHEMA cineme FROM %I', r);
            END IF;
          END LOOP;
        END $$;
        """
    )

    op.create_table(
        "users",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("display_name", sa.String(80), nullable=True),
        sa.Column("timezone", sa.String(64), server_default=sa.text("'UTC'"), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.CheckConstraint(
            "display_name IS NULL OR char_length(btrim(display_name)) > 0",
            name=op.f("ck_users_display_name_not_blank"),
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_users")),
        schema=SCHEMA,
    )

    op.create_table(
        "user_preferences",
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column(
            "genre_preferences",
            postgresql.JSONB(),
            server_default=sa.text("'{}'::jsonb"),
            nullable=False,
        ),
        sa.Column(
            "blocked_genre_ids",
            postgresql.ARRAY(sa.Integer()),
            server_default=sa.text("'{}'::integer[]"),
            nullable=False,
        ),
        sa.Column("default_max_runtime_minutes", sa.SmallInteger(), nullable=True),
        sa.Column(
            "ai_context_enabled", sa.Boolean(), server_default=sa.text("false"), nullable=False
        ),
        sa.Column("version", sa.Integer(), server_default=sa.text("1"), nullable=False),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.CheckConstraint(
            "jsonb_typeof(genre_preferences) = 'object'",
            name=op.f("ck_user_preferences_genre_preferences_object"),
        ),
        sa.CheckConstraint(
            "default_max_runtime_minutes BETWEEN 1 AND 600",
            name=op.f("ck_user_preferences_runtime_cap_range"),
        ),
        sa.CheckConstraint("version > 0", name=op.f("ck_user_preferences_version_positive")),
        sa.ForeignKeyConstraint(
            ["user_id"],
            [f"{SCHEMA}.users.id"],
            name=op.f("fk_user_preferences_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("user_id", name=op.f("pk_user_preferences")),
        schema=SCHEMA,
    )

    op.create_table(
        "idempotency_records",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("key", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("operation", sa.String(120), nullable=False),
        sa.Column("request_hash", sa.String(64), nullable=False),
        sa.Column("http_status", sa.SmallInteger(), nullable=False),
        sa.Column("response_body", postgresql.JSONB(), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "char_length(request_hash) = 64",
            name=op.f("ck_idempotency_records_request_hash_sha256"),
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            [f"{SCHEMA}.users.id"],
            name=op.f("fk_idempotency_records_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_idempotency_records")),
        sa.UniqueConstraint("user_id", "key", name=op.f("uq_idempotency_records_user_id_key")),
        schema=SCHEMA,
    )
    op.create_index(
        op.f("ix_idempotency_records_expires_at"),
        "idempotency_records",
        ["expires_at"],
        schema=SCHEMA,
    )


def downgrade() -> None:
    op.drop_index(
        op.f("ix_idempotency_records_expires_at"), table_name="idempotency_records", schema=SCHEMA
    )
    op.drop_table("idempotency_records", schema=SCHEMA)
    op.drop_table("user_preferences", schema=SCHEMA)
    op.drop_table("users", schema=SCHEMA)
    op.execute(f"DROP SCHEMA {SCHEMA}")
