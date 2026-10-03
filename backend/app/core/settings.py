import os
from collections.abc import Mapping
from typing import Literal, Self
from urllib.parse import parse_qs, urlsplit

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
    # "serverless": database_url is a transaction-mode pooler (Neon `-pooler`)
    # used from short-lived functions; see app.core.db.make_engine.
    database_pool_mode: Literal["local", "serverless"] = "local"

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
        if self.environment == "production":
            _require_tls(self.database_url, "database_url")
            if self.database_migration_url:
                _require_tls(self.database_migration_url, "database_migration_url")
        return self

    @property
    def supabase_base(self) -> str:
        return str(self.supabase_url).rstrip("/")

    @property
    def jwks_url(self) -> str:
        """Derived from the allowlisted project URL, never from a token."""
        return f"{self.supabase_base}/auth/v1/.well-known/jwks.json"


def _require_tls(url: str, name: str) -> None:
    """Hosted PostgreSQL (Neon) is reached over the internet: refuse a
    production URL that would fall back to an unencrypted connection."""
    mode = parse_qs(urlsplit(url).query).get("sslmode", [""])[0]
    if mode not in ("require", "verify-ca", "verify-full"):
        raise ValueError(
            f"{name} must set sslmode=require (or verify-ca/verify-full) in production"
        )


def load_settings(env: Mapping[str, str] = os.environ) -> Settings:
    """Read settings from environment variables named after the fields in upper case."""
    values = {name: env[name.upper()] for name in Settings.model_fields if name.upper() in env}
    return Settings.model_validate(values)
