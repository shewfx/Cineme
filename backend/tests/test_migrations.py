"""Migration smoke test and P2 schema constraints on real PostgreSQL."""

import uuid
from collections.abc import Callable

import pytest
from alembic import command
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine
from sqlalchemy.exc import IntegrityError

from tests.conftest import alembic_config

pytestmark = pytest.mark.integration


def tables(engine: Engine) -> set[str]:
    with engine.connect() as conn:
        return set(
            conn.execute(
                text("SELECT table_name FROM information_schema.tables WHERE table_schema='cineme'")
            ).scalars()
        )


# Only the documented tables: P2 (+ ADR 003 ledger), P3 movies/watchlist and
# P4 sessions/recommendations (+ ADR 006) and P5 movie blocks.
APP_TABLES = {
    "users",
    "user_preferences",
    "idempotency_records",
    "movies",
    "watchlist_entries",
    "recommendation_sessions",
    "recommendations",
    "rejection_feedback",
    "viewings",
    "movie_blocks",
    "series",
    "series_episodes",
    "series_entries",
    "episode_viewings",
    "series_blocks",
}


def test_p4_downgrade_keeps_p3_data_tables(database_factory: Callable[[], str]) -> None:
    url = database_factory()
    config = alembic_config(url)
    engine = create_engine(url)
    try:
        command.upgrade(config, "head")
        command.downgrade(config, "0002")
        assert tables(engine) == APP_TABLES - {
            "recommendation_sessions",
            "recommendations",
            "rejection_feedback",
            "viewings",
            "movie_blocks",
            "series",
            "series_episodes",
            "series_entries",
            "episode_viewings",
            "series_blocks",
        }
        command.upgrade(config, "head")
        assert tables(engine) == APP_TABLES
    finally:
        engine.dispose()


def test_empty_db_upgrade_downgrade_upgrade(database_factory: Callable[[], str]) -> None:
    url = database_factory()
    config = alembic_config(url)
    engine = create_engine(url)
    try:
        command.upgrade(config, "head")
        assert tables(engine) == APP_TABLES

        command.downgrade(config, "base")
        with engine.connect() as conn:
            schema = conn.execute(
                text("SELECT 1 FROM information_schema.schemata WHERE schema_name='cineme'")
            ).scalar()
        assert schema is None

        command.upgrade(config, "head")
        assert tables(engine) == APP_TABLES
    finally:
        engine.dispose()


def test_integer_rating_migration_preserves_legacy_values(
    database_factory: Callable[[], str],
) -> None:
    url = database_factory()
    config = alembic_config(url)
    engine = create_engine(url)
    uid = uuid.uuid4()
    try:
        command.upgrade(config, "0005")
        with engine.begin() as conn:
            conn.execute(text("INSERT INTO cineme.users (id) VALUES (:id)"), {"id": uid})
            for index, legacy in enumerate(["disliked", "okay", "liked", "loved", None]):
                movie_id = 900000 + index
                conn.execute(
                    text(
                        "INSERT INTO cineme.movies (tmdb_id, title, adult, fetched_at) "
                        "VALUES (:id, :title, false, now())"
                    ),
                    {"id": movie_id, "title": f"Film {index}"},
                )
                conn.execute(
                    text(
                        "INSERT INTO cineme.viewings "
                        "(id, user_id, movie_id, recorded_at, source, rating) "
                        "VALUES (:id, :user, :movie, now(), 'manual', :rating)"
                    ),
                    {"id": uuid.uuid4(), "user": uid, "movie": movie_id, "rating": legacy},
                )
        command.upgrade(config, "head")
        with engine.connect() as conn:
            ratings = (
                conn.execute(text("SELECT rating FROM cineme.viewings ORDER BY movie_id"))
                .scalars()
                .all()
            )
        assert ratings == [1, 3, 4, 5, None]
        with engine.begin() as conn:
            conn.execute(text("UPDATE cineme.viewings SET rating = 2 WHERE movie_id = 900000"))
        command.downgrade(config, "0005")
        with engine.connect() as conn:
            legacy_ratings = (
                conn.execute(text("SELECT rating FROM cineme.viewings ORDER BY movie_id"))
                .scalars()
                .all()
            )
        assert legacy_ratings == [
            "disliked",
            "okay",
            "liked",
            "loved",
            None,
        ]
        command.upgrade(config, "head")
        with engine.connect() as conn:
            upgraded_again = (
                conn.execute(text("SELECT rating FROM cineme.viewings ORDER BY movie_id"))
                .scalars()
                .all()
            )
        assert upgraded_again == [1, 3, 4, 5, None]
    finally:
        engine.dispose()


def test_public_has_no_access_to_the_app_schema(engine: Engine) -> None:
    with engine.connect() as conn:
        usage = conn.execute(
            text(
                "SELECT has_schema_privilege('public', 'cineme', 'USAGE') "
                "FROM pg_namespace WHERE nspname = 'cineme'"
            )
        ).scalar()
    assert usage is False


def insert_user(engine: Engine) -> uuid.UUID:
    uid = uuid.uuid4()
    with engine.begin() as conn:
        conn.execute(text("INSERT INTO cineme.users (id) VALUES (:id)"), {"id": uid})
        conn.execute(
            text("INSERT INTO cineme.user_preferences (user_id) VALUES (:id)"), {"id": uid}
        )
    return uid


def test_defaults_match_the_data_model(engine: Engine) -> None:
    uid = insert_user(engine)
    with engine.connect() as conn:
        user = conn.execute(
            text("SELECT timezone, display_name FROM cineme.users WHERE id=:id"), {"id": uid}
        ).one()
        prefs = conn.execute(
            text(
                "SELECT genre_preferences, blocked_genre_ids, default_max_runtime_minutes, "
                "ai_context_enabled, version FROM cineme.user_preferences WHERE user_id=:id"
            ),
            {"id": uid},
        ).one()
    assert tuple(user) == ("UTC", None)
    assert tuple(prefs) == ({}, [], None, False, 1)


@pytest.mark.parametrize(
    "statement",
    [
        "UPDATE cineme.user_preferences SET default_max_runtime_minutes = 0",
        "UPDATE cineme.user_preferences SET default_max_runtime_minutes = 601",
        "UPDATE cineme.user_preferences SET version = 0",
        "UPDATE cineme.user_preferences SET genre_preferences = '[1]'::jsonb",
        "UPDATE cineme.users SET display_name = '   '",
        "INSERT INTO cineme.user_preferences (user_id) VALUES (gen_random_uuid())",
    ],
)
def test_constraints_reject_invalid_rows(engine: Engine, statement: str) -> None:
    insert_user(engine)
    with pytest.raises(IntegrityError), engine.begin() as conn:
        conn.execute(text(statement))


def test_runtime_cap_bounds_are_inclusive(engine: Engine) -> None:
    insert_user(engine)
    with engine.begin() as conn:
        conn.execute(text("UPDATE cineme.user_preferences SET default_max_runtime_minutes = 1"))
        conn.execute(text("UPDATE cineme.user_preferences SET default_max_runtime_minutes = 600"))


def test_deleting_a_user_cascades_private_rows(engine: Engine) -> None:
    uid = insert_user(engine)
    with engine.begin() as conn:
        conn.execute(text("DELETE FROM cineme.users WHERE id=:id"), {"id": uid})
        left = conn.execute(
            text("SELECT count(*) FROM cineme.user_preferences WHERE user_id=:id"), {"id": uid}
        ).scalar()
    assert left == 0


def test_onboarding_migration_backfills_existing_users_only(
    database_factory: Callable[[], str],
) -> None:
    url = database_factory()
    config = alembic_config(url)
    engine = create_engine(url)
    existing, later = uuid.uuid4(), uuid.uuid4()
    try:
        command.upgrade(config, "0006")
        with engine.begin() as conn:
            conn.execute(
                text(
                    "INSERT INTO cineme.users (id, created_at) VALUES (:id, '2026-01-02 03:04+00')"
                ),
                {"id": existing},
            )
        command.upgrade(config, "head")
        with engine.begin() as conn:
            conn.execute(text("INSERT INTO cineme.users (id) VALUES (:id)"), {"id": later})
        with engine.connect() as conn:
            rows = dict(
                conn.execute(
                    text("SELECT id, onboarding_completed_at = created_at FROM cineme.users")
                ).all()
            )
            nulls = (
                conn.execute(
                    text("SELECT id FROM cineme.users WHERE onboarding_completed_at IS NULL")
                )
                .scalars()
                .all()
            )
        assert rows[existing] is True, "existing accounts are never sent through onboarding"
        assert nulls == [later], "accounts created afterwards start incomplete"

        command.downgrade(config, "0006")
        with engine.connect() as conn:
            columns = set(
                conn.execute(
                    text(
                        "SELECT column_name FROM information_schema.columns "
                        "WHERE table_schema='cineme' AND table_name='users'"
                    )
                ).scalars()
            )
        assert "onboarding_completed_at" not in columns
        command.upgrade(config, "head")
    finally:
        engine.dispose()
