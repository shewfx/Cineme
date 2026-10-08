"""The TMDB TV adapter against mocked HTTP (no network), and migration 0008."""

import uuid
from collections.abc import Callable
from datetime import date
from typing import Any

import httpx
import pytest
from alembic import command
from sqlalchemy import create_engine, text
from sqlalchemy.exc import IntegrityError

from app.core.errors import AppError
from app.movies.provider import normalize_episodes, normalize_series
from tests.conftest import alembic_config
from tests.test_tmdb_provider import TOKEN, provider


def tv_raw(**overrides: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "id": 1399,
        "name": "Alpha",
        "original_name": "Alpha",
        "first_air_date": "2015-04-01",
        "last_air_date": "2020-05-01",
        "status": "Returning Series",
        "genres": [{"id": 18, "name": "Drama"}],
        "poster_path": "/abc.jpg",
        "overview": "x",
        "vote_average": 8.1,
        "vote_count": 100,
        "origin_country": ["US", 5],
        "original_language": "en",
        "seasons": [
            {"season_number": 0, "episode_count": 4},  # specials: dropped
            {"season_number": 1, "episode_count": 10},
            {"season_number": 2, "episode_count": 8},
            {"season_number": "x", "episode_count": 1},
            {"season_number": 3, "episode_count": -1},
        ],
    }
    base.update(overrides)
    return base


def test_series_normalization_keeps_regular_seasons_and_drops_malformed_data() -> None:
    s = normalize_series(tv_raw(), details=True)
    assert s is not None
    assert (s.tmdb_id, s.name, s.original_name) == (1399, "Alpha", None)
    assert s.first_air_date == date(2015, 4, 1) and s.status == "Returning Series"
    assert s.genre_ids == (18,) and s.origin_countries == ("US",)
    assert s.seasons == ((1, 10), (2, 8)), "specials and invalid seasons never appear"
    assert normalize_series({"id": 0, "name": "x"}) is None
    assert normalize_series({"id": 5, "name": "  "}) is None
    assert normalize_series("nope") is None
    odd = normalize_series(tv_raw(first_air_date="soon", poster_path="http://x/y.jpg"))
    assert odd is not None and odd.first_air_date is None and odd.poster_path is None


def test_episode_normalization_drops_specials_and_keeps_unknowns_unknown() -> None:
    two = {
        "season_number": 1,
        "episode_number": 2,
        "name": "Two",
        "air_date": "2020-01-02",
        "runtime": 0,
        "id": 9,
    }
    one = {"season_number": 1, "episode_number": 1, "name": "One", "air_date": "", "runtime": 44}
    eps = normalize_episodes(
        {
            "episodes": [
                {"season_number": 0, "episode_number": 1, "name": "Special"},
                two,
                one,
                {"season_number": 1, "episode_number": 1, "name": "Duplicate"},
                {"season_number": 1, "episode_number": 0},
                "junk",
            ]
        }
    )
    assert [(e.season_number, e.episode_number) for e in eps] == [(1, 1), (1, 2)]
    first, second = eps
    assert first.air_date is None and first.runtime_minutes is None, "the later duplicate wins"
    assert second.runtime_minutes is None, "runtime 0 is unknown, not zero"
    assert second.air_date == date(2020, 1, 2) and second.tmdb_episode_id == 9
    assert normalize_episodes({"episodes": "x"}) == () and normalize_episodes(None) == ()


def test_seasons_are_fetched_in_chunks_of_twenty() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        wanted = request.url.params["append_to_response"].split(",")
        body: dict[str, Any] = {"id": 7}
        for item in wanted:
            n = int(item.split("/")[1])
            body[item] = {"episodes": [{"season_number": n, "episode_number": 1, "name": f"S{n}"}]}
        return httpx.Response(200, json=body)

    p, seen = provider(handler)
    eps = p.tv_episodes(7, [*range(1, 46), 0, 3])
    assert len(seen) == 3, "45 regular seasons: 20 + 20 + 5"
    assert all(len(r.url.params["append_to_response"].split(",")) <= 20 for r in requests)
    assert len(eps) == 45 and eps[0].season_number == 1 and eps[-1].season_number == 45
    assert all(r.headers["Authorization"] == f"Bearer {TOKEN}" for r in requests)


def test_tv_search_details_and_failures() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/search/tv"):
            return httpx.Response(200, json={"total_pages": 900, "results": [tv_raw(), {"x": 1}]})
        if request.url.path == "/3/tv/1399":
            return httpx.Response(200, json=tv_raw())
        if request.url.path == "/3/tv/5":
            return httpx.Response(200, json=tv_raw(id=6))  # another show than asked for
        return httpx.Response(404, json={})

    p, _ = provider(handler)
    page = p.search_tv("alpha", 1)
    assert page.total_pages == 500 and [s.name for s in page.results] == ["Alpha"]
    assert p.tv_details(1399).seasons == ((1, 10), (2, 8))
    with pytest.raises(AppError) as mismatch:
        p.tv_details(5)
    assert mismatch.value.status == 502
    with pytest.raises(AppError) as missing:
        p.tv_details(404)
    assert missing.value.status == 404


@pytest.mark.integration
def test_migration_0008_defaults_existing_users_to_movies_and_enforces_identity(
    database_factory: Callable[[], str],
) -> None:
    url = database_factory()
    config = alembic_config(url)
    engine = create_engine(url)
    uid = uuid.uuid4()
    try:
        command.upgrade(config, "0007")
        with engine.begin() as conn:
            conn.execute(text("INSERT INTO cineme.users (id) VALUES (:id)"), {"id": uid})
            conn.execute(
                text("INSERT INTO cineme.user_preferences (user_id) VALUES (:id)"), {"id": uid}
            )
        command.upgrade(config, "head")
        with engine.connect() as conn:
            media = conn.execute(text("SELECT tonight_media FROM cineme.user_preferences")).scalar()
        assert media == "movies", "existing users stay on Movies only"
        with engine.begin() as conn, pytest.raises(IntegrityError):
            conn.execute(text("UPDATE cineme.user_preferences SET tonight_media = 'everything'"))
        with engine.begin() as conn:
            conn.execute(
                text(
                    "INSERT INTO cineme.series (tmdb_id, name, adult, fetched_at) "
                    "VALUES (1, 'S', false, now())"
                )
            )
            conn.execute(
                text(
                    "INSERT INTO cineme.series_entries (id, user_id, series_id, added_at) "
                    "VALUES (gen_random_uuid(), :u, 1, now())"
                ),
                {"u": uid},
            )
        # Progress is a pair; ratings and numbers are bounded; specials are not stored.
        for sql in (
            "UPDATE cineme.series_entries SET progress_season = 1",
            "UPDATE cineme.series_entries SET series_rating = 6",
            "INSERT INTO cineme.series_episodes (series_id, season_number, episode_number,"
            " fetched_at) VALUES (1, 0, 1, now())",
        ):
            with engine.begin() as conn, pytest.raises(IntegrityError):
                conn.execute(text(sql))
        # One watch per user and episode.
        insert = (
            "INSERT INTO cineme.episode_viewings (id, user_id, series_id, season_number, "
            "episode_number, recorded_at, source) "
            "VALUES (gen_random_uuid(), :u, 1, 1, 1, now(), 'manual')"
        )
        with engine.begin() as conn:
            conn.execute(text(insert), {"u": uid})
        with engine.begin() as conn, pytest.raises(IntegrityError):
            conn.execute(text(insert), {"u": uid})
        # A recommendation names exactly one identity.
        with engine.begin() as conn:
            conn.execute(
                text(
                    "INSERT INTO cineme.recommendation_sessions (id, user_id, local_date, "
                    "timezone_snapshot, day_ends_at, context, version, created_at, updated_at) "
                    "VALUES ('00000000-0000-0000-0000-0000000000aa', :u, current_date, 'UTC', "
                    "now(), '{}'::jsonb, 1, now(), now())"
                ),
                {"u": uid},
            )
        rec = (
            "INSERT INTO cineme.recommendations (id, session_id, media_kind, series_id,"
            " season_number, episode_number, movie_id, status, total_score, engine_version,"
            " config_version, config_hash, config_snapshot, context_snapshot, winner_snapshot,"
            " exclusion_summary, reason_data, explanation, created_at) "
            "VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000aa', :kind, :series,"
            " :season, :ep, NULL, 'offered', :score, 'weighted_v2', 'weights_v2', repeat('a', 64),"
            " '{}'::jsonb, '{}'::jsonb, '{}'::jsonb, '{}'::jsonb, '{}'::jsonb, 'x', now())"
        )
        good = {"kind": "episode", "series": 1, "season": 1, "ep": 1, "score": 111.5}
        with engine.begin() as conn:
            conn.execute(text(rec), good)
        for bad in (
            good | {"kind": "movie"},  # kind and identity disagree
            good | {"season": None},  # incomplete episode identity
            good | {"score": 121},  # beyond the bounded range
        ):
            with engine.begin() as conn, pytest.raises(IntegrityError):
                conn.execute(text(rec), bad)
        command.downgrade(config, "0007")
        command.upgrade(config, "head")
    finally:
        engine.dispose()


def test_tmdb_trending_tv_is_cached_an_hour_and_survives_an_outage() -> None:
    clock = [0.0]
    state = {"fail": False}

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/3/trending/tv/week"
        if state["fail"]:
            return httpx.Response(503)
        return httpx.Response(200, json={"results": [tv_raw(), {"junk": True}]})

    p, seen = provider(handler, clock)
    first = p.trending_tv()
    assert [s.tmdb_id for s in first] == [1399], "malformed items are skipped"
    clock[0] = 3599
    p.trending_tv()
    assert len(seen) == 1
    clock[0] = 3601
    state["fail"] = True
    assert p.trending_tv() == first, "stale copy while TMDB is down"


def test_tmdb_tv_watch_providers_use_the_tv_endpoint_and_the_shared_normalizer() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/3/tv/1399/watch/providers"
        return httpx.Response(
            200,
            json={
                "results": {
                    "IN": {
                        "link": "https://www.themoviedb.org/tv/1399/watch?locale=IN",
                        "flatrate": [
                            {
                                "provider_id": 8,
                                "provider_name": "Netflix",
                                "display_priority": 1,
                                "logo_path": "/n.png",
                            }
                        ],
                    }
                }
            },
        )

    p, _ = provider(handler)
    regions = p.tv_watch_providers(1399)
    assert regions["IN"]["streaming"][0]["name"] == "Netflix"
