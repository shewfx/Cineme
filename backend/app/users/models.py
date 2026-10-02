import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    ForeignKey,
    Integer,
    SmallInteger,
    String,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import ARRAY, JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class User(Base):
    """`users` (DATA_MODEL). `id` is the verified Supabase `sub`; no email,
    password or refresh token is stored."""

    __tablename__ = "users"
    __table_args__ = (
        CheckConstraint(
            "display_name IS NULL OR char_length(btrim(display_name)) > 0",
            name="display_name_not_blank",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    display_name: Mapped[str | None] = mapped_column(String(80))
    timezone: Mapped[str] = mapped_column(String(64), server_default=text("'UTC'"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class UserPreferences(Base):
    """`user_preferences` (DATA_MODEL). Read-only through the API in P2."""

    __tablename__ = "user_preferences"
    __table_args__ = (
        CheckConstraint(
            "jsonb_typeof(genre_preferences) = 'object'", name="genre_preferences_object"
        ),
        CheckConstraint("default_max_runtime_minutes BETWEEN 1 AND 600", name="runtime_cap_range"),
        CheckConstraint("version > 0", name="version_positive"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("cineme.users.id", ondelete="CASCADE"), primary_key=True
    )
    genre_preferences: Mapped[dict[str, Any]] = mapped_column(
        JSONB, server_default=text("'{}'::jsonb")
    )
    blocked_genre_ids: Mapped[list[int]] = mapped_column(
        ARRAY(Integer), server_default=text("'{}'::integer[]")
    )
    default_max_runtime_minutes: Mapped[int | None] = mapped_column(SmallInteger)
    ai_context_enabled: Mapped[bool] = mapped_column(server_default=text("false"))
    version: Mapped[int] = mapped_column(Integer, server_default=text("1"))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
