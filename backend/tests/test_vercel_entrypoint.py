"""The Vercel entrypoint (`backend/index.py`) exposes the real application."""

import importlib
import sys

import pytest
from fastapi import FastAPI

ENV = {
    "ENVIRONMENT": "production",
    "DATABASE_URL": "postgresql+psycopg://u:pw@ep-x-pooler.neon.tech/neondb?sslmode=require",
    "DATABASE_POOL_MODE": "serverless",
    "SUPABASE_URL": "https://abc.supabase.co",
    "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_x",
    "SUPABASE_JWT_ISSUER": "https://abc.supabase.co/auth/v1",
    "TMDB_READ_ACCESS_TOKEN": "tmdb-test",
}


def test_entrypoint_exports_the_configured_app(monkeypatch: pytest.MonkeyPatch) -> None:
    for name, value in ENV.items():
        monkeypatch.setenv(name, value)
    sys.modules.pop("index", None)

    module = importlib.import_module("index")

    assert isinstance(module.app, FastAPI)
    paths = set(module.app.openapi()["paths"])
    assert {"/api/v1/me/bootstrap", "/api/v1/today", "/api/v1/watchlist"} <= paths
    # Production: API docs are not served.
    assert module.app.docs_url is None


def test_entrypoint_fails_loudly_when_misconfigured(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in ENV:
        monkeypatch.delenv(name, raising=False)
    sys.modules.pop("index", None)

    with pytest.raises(ValueError, match="database_url"):
        importlib.import_module("index")
