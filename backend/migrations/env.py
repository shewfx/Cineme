"""Alembic environment. Online migrations only, with the migration role's URL
(DATABASE_MIGRATION_URL, falling back to DATABASE_URL). Tests pass a URL via
`config.attributes["database_url"]` for disposable databases."""

import os

from alembic import context
from sqlalchemy import create_engine, pool

from app.core import idempotency  # noqa: F401  (registers idempotency_records)
from app.core.db import Base
from app.movies import models as movie_models  # noqa: F401  (registers movies)
from app.recommendations import models as recommendation_models  # noqa: F401  (P4)
from app.users import models  # noqa: F401  (registers users tables)
from app.watchlist import models as watchlist_models  # noqa: F401  (watchlist)

target_metadata = Base.metadata


def _url() -> str:
    url = (
        context.config.attributes.get("database_url")
        or os.environ.get("DATABASE_MIGRATION_URL")
        or os.environ.get("DATABASE_URL")
    )
    if not url:
        raise RuntimeError("Set DATABASE_MIGRATION_URL or DATABASE_URL to run migrations.")
    return str(url)


def run_migrations_online() -> None:
    engine = create_engine(_url(), poolclass=pool.NullPool)
    with engine.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            include_schemas=True,
            compare_type=True,
        )
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    raise RuntimeError("Offline (SQL script) migrations are not supported.")
run_migrations_online()
