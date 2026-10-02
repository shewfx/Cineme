"""Shared fixtures.

Identity: real ES256 keys generated per run, so the real TokenVerifier checks
real signatures; only the key source is local. The provider's get-user call is
a fake. Database: disposable PostgreSQL databases created from
TEST_DATABASE_URL (an admin URL, e.g. to the `postgres` database). SQLite is
never used: integration tests fail loudly without PostgreSQL.
"""

import os
import time
import uuid
from collections.abc import Callable, Iterator
from typing import Any

import jwt
import pytest
from alembic import command
from alembic.config import Config
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine, make_url

from app.core.auth import Identity, TokenVerifier
from app.core.errors import AppError
from app.core.settings import Settings
from app.main import BACKEND_DIR, create_app

PROJECT = "https://test-project.supabase.co"
ISSUER = f"{PROJECT}/auth/v1"
UNUSED_DB = "postgresql+psycopg://nobody:none@127.0.0.1:1/none"


def make_settings(database_url: str = UNUSED_DB, **overrides: Any) -> Settings:
    values: dict[str, Any] = {
        "environment": "test",
        "database_url": database_url,
        "supabase_url": PROJECT,
        "supabase_publishable_key": "sb_publishable_test_placeholder",
        "supabase_jwt_issuer": ISSUER,
    }
    values.update(overrides)
    return Settings.model_validate(values)


class Signer:
    """Mints access tokens shaped like Supabase's with a local ES256 key."""

    def __init__(self, kid: str = "test-key-1") -> None:
        self.private_key = ec.generate_private_key(ec.SECP256R1())
        self.public_key = self.private_key.public_key()
        self.kid = kid

    def token(self, user: uuid.UUID | str, **overrides: Any) -> str:
        now = int(time.time())
        claims: dict[str, Any] = {
            "iss": ISSUER,
            "aud": "authenticated",
            "sub": str(user),
            "email": f"{user}@example.test",
            "role": "authenticated",
            "is_anonymous": False,
            "iat": now,
            "exp": now + 900,
        }
        claims.update(overrides)
        claims = {k: v for k, v in claims.items() if v is not None}
        return jwt.encode(claims, self.private_key, algorithm="ES256", headers={"kid": self.kid})

    def verifier(self) -> TokenVerifier:
        return TokenVerifier(ISSUER, lambda _token: self.public_key)


class FakeIdentityProvider:
    """Stands in for GET /auth/v1/user. Confirmed unless told otherwise."""

    def __init__(self) -> None:
        self.calls: list[uuid.UUID] = []
        self.unconfirmed: set[uuid.UUID] = set()
        self.down = False

    def confirm(self, identity: Identity) -> None:
        self.calls.append(identity.user_id)
        if self.down:
            raise AppError(503, "DEPENDENCY_UNAVAILABLE", "down", retryable=True)
        if identity.user_id in self.unconfirmed:
            raise AppError(403, "EMAIL_NOT_VERIFIED", "Confirm your email address.")


@pytest.fixture
def signer() -> Signer:
    return Signer()


# --- PostgreSQL -------------------------------------------------------------


def _admin_url() -> str:
    url = os.environ.get("TEST_DATABASE_URL")
    if not url:
        pytest.fail(
            "TEST_DATABASE_URL is not set. Start PostgreSQL (docs/TOOLING.md) and set it, "
            "e.g. postgresql+psycopg://cineme:<password>@127.0.0.1:5432/postgres"
        )
    return url


@pytest.fixture(scope="session")
def database_factory() -> Iterator[Callable[[], str]]:
    """Creates empty throwaway databases; all are dropped at session end."""
    admin_url = _admin_url()
    admin = create_engine(admin_url, isolation_level="AUTOCOMMIT")
    created: list[str] = []

    def create() -> str:
        name = f"cineme_test_{uuid.uuid4().hex[:12]}"
        with admin.connect() as conn:
            conn.execute(text(f'CREATE DATABASE "{name}"'))
        created.append(name)
        return make_url(admin_url).set(database=name).render_as_string(hide_password=False)

    yield create
    with admin.connect() as conn:
        for name in created:
            conn.execute(text(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)'))
    admin.dispose()


def alembic_config(database_url: str) -> Config:
    config = Config(str(BACKEND_DIR / "alembic.ini"))
    config.set_main_option("script_location", str(BACKEND_DIR / "migrations"))
    config.attributes["database_url"] = database_url
    return config


@pytest.fixture(scope="session")
def migrated_url(database_factory: Callable[[], str]) -> str:
    url = database_factory()
    command.upgrade(alembic_config(url), "head")
    return url


@pytest.fixture
def engine(migrated_url: str) -> Iterator[Engine]:
    eng = create_engine(migrated_url)
    with eng.begin() as conn:
        conn.execute(text("TRUNCATE cineme.users CASCADE"))
    yield eng
    eng.dispose()


@pytest.fixture
def provider() -> FakeIdentityProvider:
    return FakeIdentityProvider()


@pytest.fixture
def client(
    engine: Engine, signer: Signer, provider: FakeIdentityProvider, migrated_url: str
) -> TestClient:
    app = create_app(
        make_settings(migrated_url),
        engine=engine,
        verifier=signer.verifier(),
        identity_provider=provider,
    )
    return TestClient(app)
