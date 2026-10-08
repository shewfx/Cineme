import uuid
from datetime import datetime
from typing import Any, Literal, Self
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.movies.availability import iso_countries


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
    # Chosen streaming region, and the effective one (chosen, else implied
    # by the timezone, else null). ADR 007.
    country_code: str | None
    region: str | None
    created_at: datetime
    # Null: the account still needs onboarding. Clients treat an absent field
    # (older backend) as completed.
    onboarding_completed_at: datetime | None
    preferences: PreferencesResponse


class BootstrapResponse(BaseModel):
    profile: MeResponse
    created: bool


class PreferencesPatch(BaseModel):
    """PATCH /me/preferences: supplied fields replace whole values; omitted
    fields stay; null clears only the runtime cap."""

    model_config = ConfigDict(extra="forbid")

    expected_version: int = Field(ge=1)
    genre_preferences: dict[str, float] | None = Field(default=None, max_length=50)
    blocked_genre_ids: list[int] | None = Field(default=None, max_length=20)
    default_max_runtime_minutes: int | None = Field(default=None, ge=1, le=600)
    ai_context_enabled: bool | None = None

    @model_validator(mode="after")
    def _valid(self) -> Self:
        for field in ("genre_preferences", "blocked_genre_ids", "ai_context_enabled"):
            if field in self.model_fields_set and getattr(self, field) is None:
                raise ValueError(f"{field} cannot be null")
        for key, value in (self.genre_preferences or {}).items():
            if not key.isdigit() or int(key) <= 0 or not -1 <= value <= 1:
                raise ValueError("genre_preferences maps genre ids to values in [-1, 1]")
        ids = self.blocked_genre_ids or []
        if len(set(ids)) != len(ids) or any(i <= 0 for i in ids):
            raise ValueError("blocked_genre_ids must be distinct positive ids")
        return self


class PreferencesUpdate(BaseModel):
    preferences: PreferencesResponse
    today: dict[str, Any]


class MePatch(BaseModel):
    """PATCH /me: either or both fields; unknown fields are rejected."""

    model_config = ConfigDict(extra="forbid")

    display_name: str | None = Field(default=None, max_length=80)
    timezone: str | None = Field(default=None, max_length=64)
    # Null clears the choice (the timezone's country is used instead).
    country_code: str | None = Field(default=None, min_length=2, max_length=2)
    # One-way: only `true` is accepted. Skip and Continue both send it.
    onboarding_completed: Literal[True] | None = None

    @field_validator("onboarding_completed")
    @classmethod
    def _only_true(cls, v: bool | None) -> bool | None:
        if v is None:
            raise ValueError("onboarding_completed can only be set to true")
        return v

    @field_validator("display_name")
    @classmethod
    def _not_blank(cls, v: str | None) -> str | None:
        if v is not None and not v.strip():
            raise ValueError("display_name must not be blank")
        return v.strip() if v is not None else None

    @model_validator(mode="after")
    def _something(self) -> Self:
        if not self.model_fields_set:
            raise ValueError("send display_name, timezone, country_code or onboarding_completed")
        return self

    @field_validator("country_code")
    @classmethod
    def _country(cls, v: str | None) -> str | None:
        if v is not None and v not in iso_countries():
            raise ValueError("country_code must be an ISO 3166-1 alpha-2 code, e.g. IN")
        return v

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
