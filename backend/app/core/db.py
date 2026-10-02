from collections.abc import Iterator

from fastapi import Request
from sqlalchemy import MetaData, create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

SCHEMA = "cineme"

# Stable constraint names so Alembic migrations stay reviewable.
_naming = {
    "ix": "ix_%(table_name)s_%(column_0_N_name)s",
    "uq": "uq_%(table_name)s_%(column_0_N_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}


class Base(DeclarativeBase):
    """Shared registry for feature models; every app table lives in `cineme`."""

    metadata = MetaData(schema=SCHEMA, naming_convention=_naming)


def make_engine(database_url: str) -> Engine:
    """Bounded pool; statement/lock timeouts per ARCHITECTURE (5 s / 2 s)."""
    return create_engine(
        database_url,
        pool_size=5,
        max_overflow=5,
        pool_timeout=5,
        pool_pre_ping=True,
        connect_args={
            "connect_timeout": 5,
            "options": "-c statement_timeout=5000 -c lock_timeout=2000",
        },
    )


def get_session(request: Request) -> Iterator[Session]:
    """One session per request; services own their transactions."""
    factory: sessionmaker[Session] = request.app.state.session_factory
    with factory() as session:
        yield session
