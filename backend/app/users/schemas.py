import uuid
from datetime import datetime
from typing import Any, Self
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class PreferencesResponse(BaseModel):
    version: int
    genre_preferences: dict[str, Any]
    blocked_genre_ids: list[int]
    default_max_runtime_minutes: int | None
    ai_context_enabled: bool


class MeResponse(BaseModel):
    """GET /me (API_CONTRACT). Read-only; never inserts or resets anything."""

    id: uuid.UUID
    display_name: str | None
    timezone: str
    created_at: datetime
    preferences: PreferencesResponse


class BootstrapResponse(BaseModel):
    profile: MeResponse
    created: bool


class MePatch(BaseModel):
    """PATCH /me: either or both fields; unknown fields are rejected."""

    model_config = ConfigDict(extra="forbid")

    display_name: str | None = Field(default=None, max_length=80)
    timezone: str | None = Field(default=None, max_length=64)

    @field_validator("display_name")
    @classmethod
    def _not_blank(cls, v: str | None) -> str | None:
        if v is not None and not v.strip():
            raise ValueError("display_name must not be blank")
        return v.strip() if v is not None else None

    @model_validator(mode="after")
    def _something(self) -> Self:
        if not self.model_fields_set:
            raise ValueError("send display_name, timezone or both")
        return self

    @field_validator("timezone")
    @classmethod
    def _iana(cls, v: str | None) -> str | None:
        # Defaults are not validated, so None here means an explicit null.
        if v is None:
            raise ValueError("timezone cannot be null")
        try:
            ZoneInfo(v)  # tzdata ships the IANA database on Windows too
        except (ZoneInfoNotFoundError, ValueError) as e:
            raise ValueError("timezone must be an IANA zone, e.g. Asia/Kolkata") from e
        return v
