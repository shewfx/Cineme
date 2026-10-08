"""GET /movies/trending: onboarding discovery through the existing provider."""

import uuid
from datetime import UTC, date, datetime, timedelta
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

from app.core.errors import AppError
from tests.conftest import FakeMovieProvider, Signer, film
from tests.test_tmdb_provider import TOKEN, provider, raw
from tests.test_watchlist_api import Api


@pytest.fixture
def trending_films(movies: FakeMovieProvider) -> FakeMovieProvider:
    for i in range(1, 16):
        movies.films[5000 + i] = film(5000 + i, f"Trend {i}")
    movies.films[6001] = film(6001, "Adult Trend", adult=True)
    movies.films[6002] = film(6002, "Future Trend", release_date=date(2999, 1, 1))
    movies.films[6003] = film(6003, "Undated Trend", release_date=None)
    movies.films[6004] = film(6004, "No Poster Trend", poster_path=None)
    return movies


def get(api: Api) -> Any:
    return api.client.get("/api/v1/movies/trending", headers=api.headers)


@pytest.mark.integration
def test_trending_is_bounded_ordered_and_not_personalized(
    client: TestClient, signer: Signer, trending_films: FakeMovieProvider
) -> None:
    trending_films.trending_ids = [5000 + i for i in range(1, 16)]
    a, b = Api(client, signer), Api(client, signer)
    first = get(a)
    assert first.status_code == 200
    body = first.json()
    assert [m["title"] for m in body["results"]] == [f"Trend {i}" for i in range(1, 13)]
    assert len(body["results"]) == 12, "bounded: one page, no cursor"
    assert set(body) == {"results", "in_watchlist"}
    movie = body["results"][0]
    assert movie["year"] == 2000 and movie["poster_url"].endswith("/w500/p5001.jpg")
    assert movie["can_add"] is True and movie["released"] is True
    assert get(b).json()["results"] == body["results"], "same list for every user"


@pytest.mark.integration
def test_trending_applies_the_add_eligibility_rules(
    client: TestClient, signer: Signer, trending_films: FakeMovieProvider
) -> None:
    trending_films.trending_ids = [6001, 6002, 6003, 6004, 5001]
    titles = [m["title"] for m in get(Api(client, signer)).json()["results"]]
    assert titles == ["Trend 1"], "adult, unreleased, undated and poster-less films are left out"


@pytest.mark.integration
def test_trending_hides_watched_and_blocked_and_marks_saved(
    client: TestClient, signer: Signer, trending_films: FakeMovieProvider
) -> None:
    trending_films.trending_ids = [5001, 5002, 5003, 5004]
    a, other = Api(client, signer), Api(client, signer)
    h = lambda: a.headers | {"Idempotency-Key": str(uuid.uuid4())}  # noqa: E731
    assert client.post("/api/v1/viewings", json={"tmdb_id": 5001}, headers=h()).status_code == 201
    assert client.post("/api/v1/me/blocks/5002", headers=h()).status_code in (200, 201)
    assert a.add(5003).status_code == 201

    body = get(a).json()
    assert [m["tmdb_id"] for m in body["results"]] == [5003, 5004]
    assert body["in_watchlist"] == [5003]
    # Another user's history, blocks and watchlist do not leak.
    other_body = get(other).json()
    assert [m["tmdb_id"] for m in other_body["results"]] == [5001, 5002, 5003, 5004]
    assert other_body["in_watchlist"] == []


@pytest.mark.integration
def test_trending_is_read_only_and_requires_a_profile(
    client: TestClient, signer: Signer, trending_films: FakeMovieProvider, engine: Any
) -> None:
    trending_films.trending_ids = [5001]
    assert client.get("/api/v1/movies/trending").status_code == 401
    nobody = {"Authorization": f"Bearer {signer.token(uuid.uuid4())}"}
    assert client.get("/api/v1/movies/trending", headers=nobody).status_code == 409
    a = Api(client, signer)
    get(a)
    assert a.entries().json()["items"] == [], "browsing never adds anything"


@pytest.mark.integration
def test_trending_upstream_failure_is_a_visible_retryable_503(
    client: TestClient, signer: Signer, trending_films: FakeMovieProvider
) -> None:
    a = Api(client, signer)
    trending_films.down = True
    response = get(a)
    assert response.status_code == 503
    assert response.json()["error"]["retryable"] is True
    trending_films.down = False
    trending_films.trending_ids = [5001]
    assert get(a).status_code == 200
    # Search and the watchlist were never affected by the failure.
    assert a.add(5001).status_code == 201


def test_tmdb_trending_is_cached_for_an_hour_and_survives_an_outage() -> None:
    clock = [0.0]
    state = {"fail": False}

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/3/trending/movie/week"
        assert request.headers["Authorization"] == f"Bearer {TOKEN}"
        if state["fail"]:
            return httpx.Response(503)
        return httpx.Response(200, json={"results": [raw(), {"junk": True}]})

    p, seen = provider(handler, clock)
    first = p.trending()
    assert [m.tmdb_id for m in first] == [104], "malformed items are skipped"
    clock[0] = 3599
    p.trending()
    assert len(seen) == 1, "served from cache within the hour"
    clock[0] = 3601
    state["fail"] = True
    assert p.trending() == first, "stale copy while TMDB is down"
    clock[0] = 10_000
    assert len(seen) >= 2


def test_tmdb_trending_without_a_cache_fails_visibly() -> None:
    p, _ = provider(lambda r: httpx.Response(200, json={"unexpected": 1}))
    with pytest.raises(AppError) as info:
        p.trending()
    assert info.value.status == 502


# --- popular releases (Watchlist discovery) --------------------------------------


def _today() -> date:
    return datetime.now(UTC).date()  # test users keep the default UTC timezone


@pytest.fixture
def released(movies: FakeMovieProvider) -> FakeMovieProvider:
    today = _today()
    month_start = today.replace(day=1)
    year_start = today.replace(month=1, day=1)
    # Popularity order is the order of popular_ids.
    movies.films[7001] = film(7001, "This Month A", release_date=today)
    movies.films[7002] = film(7002, "This Month B", release_date=month_start)
    # Earlier in the year, or before it, depending on today's date.
    movies.films[7003] = film(7003, "Earlier This Year", release_date=year_start)
    movies.films[7004] = film(7004, "Last Year", release_date=year_start - timedelta(days=1))
    movies.popular_ids = [7001, 7003, 7002, 7004]
    return movies


def popular(api: Api, period: str) -> Any:
    return api.client.get("/api/v1/movies/popular", params={"period": period}, headers=api.headers)


@pytest.mark.integration
def test_popular_releases_use_the_callers_local_calendar_window(
    client: TestClient, signer: Signer, released: FakeMovieProvider
) -> None:
    a = Api(client, signer)
    today = _today()
    month = popular(a, "month").json()
    assert month["period"] == "month"
    assert month["released_from"] == today.replace(day=1).isoformat()
    assert month["released_to"] == today.isoformat()
    assert [m["title"] for m in month["results"]] == ["This Month A", "This Month B"]
    year = popular(a, "year").json()
    assert year["released_from"] == today.replace(month=1, day=1).isoformat()
    assert year["released_to"] == today.isoformat()
    titles = [m["title"] for m in year["results"]]
    assert "Last Year" not in titles and titles[0] == "This Month A"
    # Popularity order from TMDB is preserved, never re-ranked.
    assert titles.index("Earlier This Year") < titles.index("This Month B") or (
        today.replace(month=1, day=1) == today.replace(day=1)
    )
    assert released.popular_windows[0] == (today.replace(day=1), today)


@pytest.mark.integration
def test_popular_releases_apply_the_same_eligibility_and_bounds(
    client: TestClient, signer: Signer, released: FakeMovieProvider
) -> None:
    today = _today()
    for i in range(1, 16):
        released.films[7100 + i] = film(7100 + i, f"Pop {i}", release_date=today)
    released.films[7200] = film(7200, "Adult Pop", adult=True, release_date=today)
    released.films[7201] = film(7201, "No Poster Pop", poster_path=None, release_date=today)
    released.popular_ids = [7200, 7201] + [7100 + i for i in range(1, 16)]
    a, other = Api(client, signer), Api(client, signer)
    body = popular(a, "month").json()
    assert [m["title"] for m in body["results"]] == [f"Pop {i}" for i in range(1, 13)]
    assert set(body) == {"period", "released_from", "released_to", "results", "in_watchlist"}

    headers = a.headers | {"Idempotency-Key": str(uuid.uuid4())}
    assert (
        a.client.post("/api/v1/viewings", json={"tmdb_id": 7101}, headers=headers).status_code
        == 201
    )
    headers = a.headers | {"Idempotency-Key": str(uuid.uuid4())}
    assert a.client.post("/api/v1/me/blocks/7102", headers=headers).status_code in (200, 201)
    assert a.add(7103).status_code == 201
    mine = popular(a, "month").json()
    ids = [m["tmdb_id"] for m in mine["results"]]
    assert 7101 not in ids and 7102 not in ids and 7103 in ids
    assert mine["in_watchlist"] == [7103]
    theirs = popular(other, "month").json()
    assert 7101 in [m["tmdb_id"] for m in theirs["results"]] and theirs["in_watchlist"] == []


@pytest.mark.integration
def test_popular_validation_auth_failure_and_read_only(
    client: TestClient, signer: Signer, released: FakeMovieProvider
) -> None:
    a = Api(client, signer)
    assert popular(a, "decade").status_code == 422
    assert a.client.get("/api/v1/movies/popular", headers=a.headers).status_code == 422
    assert a.client.get("/api/v1/movies/popular?period=month").status_code == 401
    released.down = True
    failed = popular(a, "year")
    assert failed.status_code == 503 and failed.json()["error"]["retryable"] is True
    released.down = False
    assert popular(a, "year").status_code == 200
    assert a.entries().json()["items"] == [], "browsing never adds anything"


def test_tmdb_popular_releases_query_cache_and_bounds() -> None:
    clock = [0.0]
    state = {"fail": False}
    seen_params: list[dict[str, str]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/3/discover/movie"
        seen_params.append(dict(request.url.params))
        if state["fail"]:
            return httpx.Response(503)
        return httpx.Response(200, json={"results": [raw(), {"junk": True}]})

    p, seen = provider(handler, clock)
    start, end = date(2026, 10, 1), date(2026, 10, 8)
    first = p.popular_releases(start, end)
    assert [m.tmdb_id for m in first] == [104]
    params = seen_params[0]
    assert params["sort_by"] == "popularity.desc" and params["include_adult"] == "false"
    assert params["primary_release_date.gte"] == "2026-10-01"
    assert params["primary_release_date.lte"] == "2026-10-08"
    assert params["page"] == "1"
    p.popular_releases(start, end)
    assert len(seen) == 1, "cached for the window within the hour"

    clock[0] = 3601
    state["fail"] = True
    assert p.popular_releases(start, end) == first, "stale copy while TMDB is down"
    with pytest.raises(AppError):
        p.popular_releases(date(2026, 1, 1), end)

    state["fail"] = False
    for day in range(1, 12):  # more windows than the cache keeps
        p.popular_releases(date(2025, 1, day), end)
    assert len(p._popular) == 8
