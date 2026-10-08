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
from collections.abc import Callable, Iterator, Sequence
from dataclasses import replace
from datetime import date
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
from app.movies.provider import (
    GenreRef,
    ProviderEpisode,
    ProviderMovie,
    ProviderSearchPage,
    ProviderSeries,
    ProviderTvPage,
    normalize_watch_providers,
)

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
        "tmdb_read_access_token": "tmdb-test-placeholder",
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


def film(tmdb_id: int, title: str, **overrides: Any) -> ProviderMovie:
    values: dict[str, Any] = {
        "tmdb_id": tmdb_id,
        "title": title,
        "original_title": None,
        "release_date": date(2000, 1, 1),
        "genre_ids": (18,),
        "poster_path": f"/p{tmdb_id}.jpg",
        "overview": None,
        "adult": False,
        "vote_average": 7.0,
        "vote_count": 100,
        "runtime_minutes": 100,
        "original_language": "en",
        "genres": (GenreRef(18, "Drama"),),
    }
    values.update(overrides)
    return ProviderMovie(**values)


def tv(tmdb_id: int, name: str, **overrides: Any) -> ProviderSeries:
    values: dict[str, Any] = {
        "tmdb_id": tmdb_id,
        "name": name,
        "original_name": None,
        "first_air_date": date(2015, 1, 1),
        "last_air_date": date(2020, 1, 1),
        "status": "Returning Series",
        "genre_ids": (18,),
        "poster_path": f"/s{tmdb_id}.jpg",
        "overview": None,
        "adult": False,
        "vote_average": 8.0,
        "vote_count": 500,
        "original_language": "en",
        "origin_countries": ("US",),
        "seasons": ((1, 3),),
    }
    values.update(overrides)
    return ProviderSeries(**values)


def episodes_for(
    seasons: tuple[tuple[int, int], ...], *, air: date = date(2020, 1, 1), runtime: int | None = 45
) -> tuple[ProviderEpisode, ...]:
    """Regular episodes numbered 1..count in each season, all aired on `air`."""
    return tuple(
        ProviderEpisode(s, e, s * 1000 + e, f"S{s}E{e}", air, runtime)
        for s, count in seasons
        for e in range(1, count + 1)
    )


class FakeMovieProvider:
    """Scripted TMDB stand-in; counts calls and can be taken down."""

    def __init__(self, films: list[ProviderMovie] | None = None) -> None:
        self.films = {f.tmdb_id: f for f in films or []}
        self.down = False
        self.detail_calls: list[int] = []
        # Raw TMDB /watch/providers payloads by film; normalized like TMDB's.
        self.availability: dict[int, dict[str, Any]] = {}
        self.availability_calls: list[int] = []
        # Trending order (ids of `films`); empty by default.
        self.trending_ids: list[int] = []
        self.trending_calls = 0
        # Shows: series by id and their regular episodes (None: no data).
        self.series: dict[int, ProviderSeries] = {}
        self.episodes: dict[int, tuple[ProviderEpisode, ...]] = {}
        self.tv_detail_calls: list[int] = []
        self.trending_tv_ids: list[int] = []
        self.trending_tv_calls = 0
        # Raw TMDB /tv/{id}/watch/providers payloads by show.
        self.tv_availability: dict[int, dict[str, Any]] = {}
        self.tv_availability_calls: list[int] = []
        # Popular-release candidates in popularity order, filtered by window.
        self.popular_ids: list[int] = []
        self.popular_windows: list[tuple[date, date]] = []

    def _check(self) -> None:
        if self.down:
            raise AppError(503, "DEPENDENCY_UNAVAILABLE", "down", retryable=True)

    def search(self, query: str, page: int) -> ProviderSearchPage:
        self._check()
        hits = [
            # Search results never carry runtime or genre names.
            replace(f, runtime_minutes=None, genres=())
            for f in self.films.values()
            if query.lower() in f.title.lower()
        ]
        return ProviderSearchPage(page=page, total_pages=1 if hits else 0, results=tuple(hits))

    def trending(self) -> tuple[ProviderMovie, ...]:
        self.trending_calls += 1
        self._check()
        return tuple(
            replace(self.films[i], runtime_minutes=None, genres=())
            for i in self.trending_ids
            if i in self.films
        )

    def popular_releases(self, start: date, end: date) -> tuple[ProviderMovie, ...]:
        self.popular_windows.append((start, end))
        self._check()
        return tuple(
            replace(self.films[i], runtime_minutes=None, genres=())
            for i in self.popular_ids
            if i in self.films
            and (d := self.films[i].release_date) is not None
            and start <= d <= end
        )

    def search_tv(self, query: str, page: int) -> ProviderTvPage:
        self._check()
        hits = tuple(
            replace(s, seasons=()) for s in self.series.values() if query.lower() in s.name.lower()
        )
        return ProviderTvPage(page=page, total_pages=1 if hits else 0, results=hits)

    def trending_tv(self) -> tuple[ProviderSeries, ...]:
        self.trending_tv_calls += 1
        self._check()
        return tuple(
            replace(self.series[i], seasons=()) for i in self.trending_tv_ids if i in self.series
        )

    def tv_watch_providers(self, tmdb_id: int) -> dict[str, Any]:
        self.tv_availability_calls.append(tmdb_id)
        self._check()
        return normalize_watch_providers(
            {"id": tmdb_id, "results": self.tv_availability.get(tmdb_id, {})}
        )

    def tv_details(self, tmdb_id: int) -> ProviderSeries:
        self.tv_detail_calls.append(tmdb_id)
        self._check()
        if tmdb_id not in self.series:
            raise AppError(404, "NOT_FOUND", "That show was not found.")
        return self.series[tmdb_id]

    def tv_episodes(self, tmdb_id: int, seasons: Sequence[int]) -> tuple[ProviderEpisode, ...]:
        self._check()
        return tuple(e for e in self.episodes.get(tmdb_id, ()) if e.season_number in seasons)

    def tv_genres(self) -> tuple[GenreRef, ...]:
        self._check()
        return (GenreRef(10759, "Action & Adventure"), GenreRef(18, "Drama"))

    def details(self, tmdb_id: int) -> ProviderMovie:
        self.detail_calls.append(tmdb_id)
        self._check()
        if tmdb_id not in self.films:
            raise AppError(404, "NOT_FOUND", "That film was not found.")
        return self.films[tmdb_id]

    def genres(self) -> tuple[GenreRef, ...]:
        self._check()
        return (GenreRef(18, "Drama"), GenreRef(28, "Action"))

    def image_base(self) -> str:
        return "https://image.tmdb.org/t/p/"

    def watch_providers(self, tmdb_id: int) -> dict[str, Any]:
        self.availability_calls.append(tmdb_id)
        self._check()
        return normalize_watch_providers(
            {"id": tmdb_id, "results": self.availability.get(tmdb_id, {})}
        )

    def watch_regions(self) -> tuple[tuple[str, str], ...]:
        self._check()
        return (("IN", "India"), ("US", "United States of America"))


@pytest.fixture
def movies() -> FakeMovieProvider:
    return FakeMovieProvider(
        [
            film(104, "Run Lola Run", runtime_minutes=81, genre_ids=(28, 18)),
            film(329865, "Arrival", runtime_minutes=116),
            film(14337, "Primer", runtime_minutes=77, poster_path=None),
            film(888, "Future Film", release_date=date(2999, 1, 1)),
            film(889, "Undated Film", release_date=None),
            film(890, "Adult Film", adult=True),
        ]
    )


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
        conn.execute(text("TRUNCATE cineme.users, cineme.movies, cineme.series CASCADE"))
    yield eng
    eng.dispose()


@pytest.fixture
def provider() -> FakeIdentityProvider:
    return FakeIdentityProvider()


@pytest.fixture
def client(
    engine: Engine,
    signer: Signer,
    provider: FakeIdentityProvider,
    movies: FakeMovieProvider,
    migrated_url: str,
) -> TestClient:
    app = create_app(
        make_settings(migrated_url),
        engine=engine,
        verifier=signer.verifier(),
        identity_provider=provider,
        movie_provider=movies,
    )
    return TestClient(app)
