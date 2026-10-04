from collections.abc import Iterator
from typing import Literal

from fastapi import Request
from sqlalchemy import MetaData, create_engine, event
from sqlalchemy.engine import Connection, Engine
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


STATEMENT_TIMEOUT_MS = 5000
LOCK_TIMEOUT_MS = 2000


def make_engine(database_url: str, pool_mode: Literal["local", "serverless"] = "local") -> Engine:
    """Bounded pool; statement/lock timeouts per ARCHITECTURE (5 s / 2 s).

    `serverless` is for a transaction-mode pooler (Neon's `-pooler` host) in
    front of short-lived functions. The pooler rejects the `options` startup
    parameter and shares server sessions between clients, so the timeouts are
    applied with `SET LOCAL` at the start of every transaction instead, driver
    prepared statements are off, and this process keeps only a small pool."""
    if pool_mode == "local":
        return create_engine(
            database_url,
            pool_size=5,
            max_overflow=5,
            pool_timeout=5,
            pool_pre_ping=True,
            connect_args={
                "connect_timeout": 5,
                "options": f"-c statement_timeout={STATEMENT_TIMEOUT_MS} "
                f"-c lock_timeout={LOCK_TIMEOUT_MS}",
            },
        )
    engine = create_engine(
        database_url,
        pool_size=2,
        max_overflow=3,
        pool_timeout=5,
        pool_pre_ping=True,
        pool_recycle=300,
        # A suspended Neon compute can take a few seconds to wake.
        connect_args={"connect_timeout": 10, "prepare_threshold": None},
    )

    @event.listens_for(engine, "begin")
    def _transaction_timeouts(conn: Connection) -> None:
        conn.exec_driver_sql(f"SET LOCAL statement_timeout = {STATEMENT_TIMEOUT_MS}")
        conn.exec_driver_sql(f"SET LOCAL lock_timeout = {LOCK_TIMEOUT_MS}")

    return engine


def get_session(request: Request) -> Iterator[Session]:
    """One session per request; services own their transactions."""
    factory: sessionmaker[Session] = request.app.state.session_factory
    with factory() as session:
        yield session
