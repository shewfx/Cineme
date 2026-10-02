import os
from collections.abc import Mapping
from typing import Literal, Self

from pydantic import BaseModel, ConfigDict, HttpUrl, model_validator


class Settings(BaseModel):
    """Settings validated at startup. From P2 the app needs PostgreSQL and the
    Supabase Auth project; from P3 the TMDB read token (ARCHITECTURE
    "Configuration and secrets"). AI settings arrive with their phase."""

    model_config = ConfigDict(frozen=True)

    environment: Literal["development", "test", "production"] = "development"
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"

    # SQLAlchemy URL for the least-privilege app role, e.g.
    # postgresql+psycopg://cineme_app:...@127.0.0.1:5432/cineme
    database_url: str
    # Migrations may use a separate role; defaults to database_url.
    database_migration_url: str | None = None

    supabase_url: HttpUrl
    supabase_publishable_key: str
    supabase_jwt_issuer: str

    # P3: backend-only TMDB v4 read access token. Never sent to Flutter.
    tmdb_read_access_token: str

    @model_validator(mode="after")
    def _issuer_matches_project(self) -> Self:
        expected = f"{str(self.supabase_url).rstrip('/')}/auth/v1"
        if self.supabase_jwt_issuer != expected:
            raise ValueError(f"supabase_jwt_issuer must be {expected}")
        if not self.database_url.startswith("postgresql+psycopg://"):
            raise ValueError("database_url must use the postgresql+psycopg driver")
        return self

    @property
    def supabase_base(self) -> str:
        return str(self.supabase_url).rstrip("/")

    @property
    def jwks_url(self) -> str:
        """Derived from the allowlisted project URL, never from a token."""
        return f"{self.supabase_base}/auth/v1/.well-known/jwks.json"


def load_settings(env: Mapping[str, str] = os.environ) -> Settings:
    """Read settings from environment variables named after the fields in upper case."""
    values = {name: env[name.upper()] for name in Settings.model_fields if name.upper() in env}
    return Settings.model_validate(values)
