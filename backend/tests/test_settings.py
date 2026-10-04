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


PROD = {
    **BASE,
    "ENVIRONMENT": "production",
    "DATABASE_URL": "postgresql+psycopg://u:pw@ep-x-pooler.neon.tech/neondb?sslmode=require",
}


def test_reads_p2_configuration() -> None:
    settings = load_settings({**PROD, "LOG_LEVEL": "WARNING"})

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


def test_production_database_urls_must_require_tls() -> None:
    plain = "postgresql+psycopg://u:pw@ep-x.neon.tech/neondb"
    with pytest.raises(ValidationError, match="database_url must set sslmode"):
        load_settings({**PROD, "DATABASE_URL": plain})
    with pytest.raises(ValidationError, match="database_migration_url must set sslmode"):
        load_settings({**PROD, "DATABASE_MIGRATION_URL": plain + "?sslmode=prefer"})
    ok = load_settings({**PROD, "DATABASE_MIGRATION_URL": plain + "?sslmode=verify-full"})
    assert ok.database_migration_url is not None


def test_local_development_does_not_need_tls_and_defaults_to_local_pool() -> None:
    settings = load_settings(BASE)
    assert settings.database_pool_mode == "local"


def test_pool_mode_is_explicit() -> None:
    assert load_settings({**BASE, "DATABASE_POOL_MODE": "serverless"}).database_pool_mode == (
        "serverless"
    )
    with pytest.raises(ValidationError, match="database_pool_mode"):
        load_settings({**BASE, "DATABASE_POOL_MODE": "pgbouncer"})
