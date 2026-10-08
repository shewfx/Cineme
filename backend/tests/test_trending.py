"""GET /movies/trending: onboarding discovery through the existing provider."""

import uuid
from datetime import date
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
