"""Engine modes. The serverless mode targets a transaction-mode pooler (Neon
`-pooler`), which rejects the `options` startup parameter; the real database
here proves the per-transaction timeouts still apply."""

import pytest
from sqlalchemy import text
from sqlalchemy.engine import Engine

from app.core.db import make_engine

pytestmark = pytest.mark.integration


def _timeouts(url: str, mode: str) -> tuple[str, str]:
    engine = make_engine(url, mode)  # type: ignore[arg-type]
    try:
        with engine.begin() as conn:
            return (
                conn.execute(text("SHOW statement_timeout")).scalar_one(),
                conn.execute(text("SHOW lock_timeout")).scalar_one(),
            )
    finally:
        engine.dispose()


def test_local_mode_sets_timeouts_as_startup_options(engine: Engine) -> None:
    url = engine.url.render_as_string(hide_password=False)
    assert _timeouts(url, "local") == ("5s", "2s")


def test_serverless_mode_sets_timeouts_per_transaction_without_startup_options(
    engine: Engine,
) -> None:
    url = engine.url.render_as_string(hide_password=False)
    eng = make_engine(url, "serverless")
    try:
        assert "options" not in eng.dialect.create_connect_args(eng.url)[1]
        assert _timeouts(url, "serverless") == ("5s", "2s")
    finally:
        eng.dispose()


def test_serverless_mode_disables_driver_prepared_statements(engine: Engine) -> None:
    url = engine.url.render_as_string(hide_password=False)
    eng = make_engine(url, "serverless")
    try:
        with eng.begin() as conn:
            for _ in range(8):  # psycopg would auto-prepare after 5 identical statements
                conn.execute(text("SELECT 1"))
            prepared = conn.execute(
                text("SELECT count(*) FROM pg_prepared_statements")
            ).scalar_one()
        assert prepared == 0
    finally:
        eng.dispose()
