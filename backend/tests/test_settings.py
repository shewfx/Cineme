import pytest
from pydantic import ValidationError

from app.core.settings import load_settings

BASE = {
    "DATABASE_URL": "postgresql+psycopg://app:pw@127.0.0.1:5432/cineme",
    "SUPABASE_URL": "https://abc.supabase.co",
    "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_x",
    "SUPABASE_JWT_ISSUER": "https://abc.supabase.co/auth/v1",
    "TMDB_READ_ACCESS_TOKEN": "tmdb-test",
}


def test_reads_p2_configuration() -> None:
    settings = load_settings({**BASE, "ENVIRONMENT": "production", "LOG_LEVEL": "WARNING"})

    assert settings.environment == "production"
    assert settings.jwks_url == "https://abc.supabase.co/auth/v1/.well-known/jwks.json"
    assert settings.database_migration_url is None


@pytest.mark.parametrize(
    "missing",
    [
        "DATABASE_URL",
        "SUPABASE_URL",
        "SUPABASE_PUBLISHABLE_KEY",
        "SUPABASE_JWT_ISSUER",
        "TMDB_READ_ACCESS_TOKEN",
    ],
)
def test_p2_requires_database_and_identity_settings(missing: str) -> None:
    env = {k: v for k, v in BASE.items() if k != missing}
    with pytest.raises(ValidationError) as info:
        load_settings(env)
    assert missing.lower() in str(info.value)


def test_issuer_must_belong_to_the_configured_project() -> None:
    with pytest.raises(ValidationError, match="supabase_jwt_issuer"):
        load_settings({**BASE, "SUPABASE_JWT_ISSUER": "https://evil.supabase.co/auth/v1"})


def test_rejects_non_psycopg_database_urls() -> None:
    with pytest.raises(ValidationError, match="psycopg"):
        load_settings({**BASE, "DATABASE_URL": "sqlite:///cineme.db"})


def test_invalid_environment_fails_clearly() -> None:
    with pytest.raises(ValidationError, match="environment"):
        load_settings({**BASE, "ENVIRONMENT": "staging"})
