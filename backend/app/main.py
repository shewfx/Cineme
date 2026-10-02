import logging
from pathlib import Path

import httpx
from alembic.config import Config
from alembic.script import ScriptDirectory
from fastapi import FastAPI
from fastapi.responses import JSONResponse
from sqlalchemy import text
from sqlalchemy.engine import Engine
from sqlalchemy.orm import sessionmaker

from app.core.auth import (
    IdentityProvider,
    SupabaseIdentityProvider,
    TokenVerifier,
    jwks_key_resolver,
)
from app.core.db import make_engine
from app.core.errors import install_error_handling
from app.core.settings import Settings, load_settings
from app.movies.provider import MovieMetadataProvider, TmdbProvider
from app.movies.router import router as movies_router
from app.recommendations.router import router as recommendations_router
from app.users.router import router as users_router
from app.watchlist.router import router as watchlist_router

BACKEND_DIR = Path(__file__).resolve().parents[1]


def migration_head() -> str | None:
    config = Config(str(BACKEND_DIR / "alembic.ini"))
    config.set_main_option("script_location", str(BACKEND_DIR / "migrations"))
    return ScriptDirectory.from_config(config).get_current_head()


def create_app(
    settings: Settings,
    *,
    engine: Engine | None = None,
    verifier: TokenVerifier | None = None,
    identity_provider: IdentityProvider | None = None,
    movie_provider: MovieMetadataProvider | None = None,
) -> FastAPI:
    """Collaborators default to the configured project, database and TMDB.
    Tests pass their own signing keys and fake providers; there is no
    disabled-auth mode and no fake-results fallback."""
    logging.basicConfig(level=settings.log_level)
    docs_enabled = settings.environment != "production"
    app = FastAPI(
        title="Cinemé API",
        docs_url="/docs" if docs_enabled else None,
        redoc_url=None,
        openapi_url="/openapi.json" if docs_enabled else None,
    )
    engine = engine or make_engine(settings.database_url)
    app.state.session_factory = sessionmaker(engine, expire_on_commit=False)
    app.state.verifier = verifier or TokenVerifier(
        settings.supabase_jwt_issuer, jwks_key_resolver(settings.jwks_url)
    )
    app.state.identity_provider = identity_provider or SupabaseIdentityProvider(
        settings.supabase_base,
        settings.supabase_publishable_key,
        httpx.Client(timeout=httpx.Timeout(5.0, connect=2.0)),
    )
    app.state.movie_provider = movie_provider or TmdbProvider(settings.tmdb_read_access_token)
    head = migration_head()
    install_error_handling(app)

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/readyz", response_model=None)
    def readyz() -> dict[str, str] | JSONResponse:
        """Short DB query plus migration compatibility; not provider health."""
        try:
            with engine.connect() as conn:
                current = conn.execute(text("SELECT version_num FROM alembic_version")).scalar()
        except Exception:
            return JSONResponse({"status": "not_ready"}, status_code=503)
        if current != head:
            return JSONResponse({"status": "not_ready"}, status_code=503)
        return {"status": "ready"}

    app.include_router(users_router)
    app.include_router(movies_router)
    app.include_router(watchlist_router)
    app.include_router(recommendations_router)
    return app


def build_app() -> FastAPI:
    """ASGI factory for `uvicorn app.main:build_app --factory`."""
    return create_app(load_settings())
