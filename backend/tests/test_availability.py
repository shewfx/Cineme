"""Streaming availability (ADR 007): JustWatch data via TMDB, per region,
cached on the shared movie row; display-only. TMDB is always faked."""

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlalchemy.engine import Engine

from app.core.errors import AppError
from app.movies.provider import TmdbProvider, normalize_watch_providers
from tests.conftest import FakeMovieProvider, Signer
from tests.test_watchlist_api import Api, scalar

LOLA = 104


def offer(pid: int, name: str, priority: int = 1, logo: str | None = "/l.png") -> dict[str, Any]:
    return {
        "provider_id": pid,
        "provider_name": name,
        "display_priority": priority,
        "logo_path": logo,
    }


IN_PAYLOAD = {
    "IN": {
        "link": "https://www.themoviedb.org/movie/104/watch?locale=IN",
        "flatrate": [offer(122, "JioHotstar", 2), offer(8, "Netflix", 1)],
        "ads": [offer(300, "Pluto TV", 3)],
        "rent": [offer(2, "Apple TV", 1)],
        "buy": [offer(2, "Apple TV", 1), offer(3, "Google Play Movies", 2)],
    },
    "US": {"flatrate": [offer(9, "Amazon Prime Video", 1)]},
}


# --- normalization (unit) -------------------------------------------------------------


def test_normalization_groups_sorts_and_vets() -> None:
    raw = {
        "results": IN_PAYLOAD
        | {
            "xx": {"flatrate": [offer(1, "Bad region")]},
            "GB": {
                "link": "https://evil.example/watch",
                "flatrate": [
                    offer(8, "Netflix"),
                    offer(8, "Netflix duplicate"),
                    {"provider_id": "7", "provider_name": "Bad id"},
                    {"provider_id": 5, "provider_name": "  "},
                    offer(6, "Odd logo", logo="javascript:alert(1)"),
                    "junk",
                ],
            },
        }
    }
    regions = normalize_watch_providers(raw)
    assert set(regions) == {"IN", "US", "GB"}
    india = regions["IN"]
    assert [o["name"] for o in india["streaming"]] == ["Netflix", "JioHotstar"]
    assert [o["name"] for o in india["free"]] == ["Pluto TV"]
    assert [o["name"] for o in india["rent"]] == ["Apple TV"]
    assert [o["name"] for o in india["buy"]] == ["Apple TV", "Google Play Movies"]
    assert india["link"].startswith("https://www.themoviedb.org/")
    gb = regions["GB"]
    assert gb["link"] is None, "only TMDB's own watch page link"
    assert [o["name"] for o in gb["streaming"]] == ["Netflix", "Odd logo"]
    assert gb["streaming"][1]["logo_path"] is None


@pytest.mark.parametrize("raw", [None, [], {"id": 1}, {"results": []}])
def test_malformed_payload_is_an_upstream_error(raw: object) -> None:
    with pytest.raises(AppError) as e:
        normalize_watch_providers(raw)
    assert e.value.status == 502


def test_tmdb_provider_calls_the_watch_endpoint_once_for_all_regions() -> None:
    seen: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request.url.path)
        return httpx.Response(200, json={"id": 104, "results": IN_PAYLOAD})

    provider = TmdbProvider("token", httpx.Client(transport=httpx.MockTransport(handler)))
    regions = provider.watch_providers(104)
    assert seen == ["/3/movie/104/watch/providers"]
    assert regions["IN"]["streaming"][0]["name"] == "Netflix"


# --- API (PostgreSQL) -----------------------------------------------------------------


class Viewer(Api):
    def availability(self, tmdb_id: int = LOLA) -> Any:
        return self.client.get(f"/api/v1/movies/{tmdb_id}/availability", headers=self.headers)

    def set(self, **fields: Any) -> Any:
        return self.client.patch(
            "/api/v1/me",
            json=fields,
            headers=self.headers | {"Idempotency-Key": str(uuid.uuid4())},
        )


@pytest.fixture
def v(client: TestClient, signer: Signer, movies: FakeMovieProvider) -> Viewer:
    movies.availability[LOLA] = IN_PAYLOAD
    viewer = Viewer(client, signer)
    viewer.add(LOLA)  # caches the film's metadata
    return viewer


@pytest.mark.integration
def test_region_comes_from_the_timezone_until_chosen(v: Viewer, movies: FakeMovieProvider) -> None:
    body = v.availability().json()
    assert body["region"] is None, "UTC implies no country"
    assert body["streaming"] == [] and movies.availability_calls == []

    assert v.set(timezone="Asia/Kolkata").json()["region"] == "IN"
    body = v.availability().json()
    assert body["region"] == "IN"
    assert [p["name"] for p in body["streaming"]] == ["Netflix", "JioHotstar"]
    assert body["streaming"][0]["logo_url"] == "https://image.tmdb.org/t/p/w92/l.png"
    assert [p["name"] for p in body["free"]] == ["Pluto TV"]
    assert [p["name"] for p in body["rent"]] == ["Apple TV"]

    me = v.set(country_code="US").json()
    assert me["country_code"] == "US" and me["region"] == "US"
    assert [p["name"] for p in v.availability().json()["streaming"]] == ["Amazon Prime Video"]
    assert v.set(country_code=None).json()["region"] == "IN"


@pytest.mark.integration
@pytest.mark.parametrize("bad", ["in", "XX", "IND", "1N"])
def test_country_code_must_be_a_real_iso_code(v: Viewer, bad: str) -> None:
    r = v.set(country_code=bad)
    assert r.status_code == 422


@pytest.mark.integration
def test_no_providers_is_empty_never_invented(v: Viewer, movies: FakeMovieProvider) -> None:
    movies.availability[LOLA] = {"US": IN_PAYLOAD["US"]}
    v.set(country_code="IN")
    body = v.availability().json()
    assert body["region"] == "IN"
    assert body["streaming"] == body["free"] == body["rent"] == body["buy"] == []
    assert body["link"] is None


@pytest.mark.integration
def test_availability_is_cached_and_refreshed_after_a_day(
    v: Viewer, movies: FakeMovieProvider, engine: Engine
) -> None:
    v.set(country_code="IN")
    v.availability()
    v.availability()
    assert movies.availability_calls == [LOLA], "cached on the shared movie row"
    with engine.begin() as conn:
        conn.execute(
            text("UPDATE cineme.movies SET watch_providers_fetched_at = :t"),
            {"t": datetime.now(UTC) - timedelta(hours=25)},
        )
    movies.availability[LOLA] = {"IN": {"flatrate": [offer(11, "MUBI")]}}
    body = v.availability().json()
    assert movies.availability_calls == [LOLA, LOLA]
    assert [p["name"] for p in body["streaming"]] == ["MUBI"]


@pytest.mark.integration
def test_provider_failure_keeps_old_data_or_fails_visibly(
    v: Viewer, movies: FakeMovieProvider, engine: Engine
) -> None:
    v.set(country_code="IN")
    movies.down = True
    assert v.availability().status_code == 503, "nothing cached: visible failure"
    movies.down = False
    v.availability()
    with engine.begin() as conn:
        conn.execute(
            text("UPDATE cineme.movies SET watch_providers_fetched_at = :t"),
            {"t": datetime.now(UTC) - timedelta(days=3)},
        )
    movies.down = True
    body = v.availability().json()
    assert body["stale"] is True
    assert [p["name"] for p in body["streaming"]] == ["Netflix", "JioHotstar"]


@pytest.mark.integration
def test_unknown_film_is_404_and_auth_is_required(v: Viewer, client: TestClient) -> None:
    assert v.availability(424242).status_code == 404
    assert client.get(f"/api/v1/movies/{LOLA}/availability").status_code == 401


@pytest.mark.integration
def test_regions_list(v: Viewer) -> None:
    items = v.client.get("/api/v1/watch/regions", headers=v.headers).json()["items"]
    assert {"code": "IN", "name": "India"} in items


@pytest.mark.integration
def test_choosing_never_calls_the_availability_service(
    v: Viewer, movies: FakeMovieProvider
) -> None:
    v.set(country_code="IN")
    r = v.client.post(
        "/api/v1/today/choose",
        json={"expected_session_version": 0, "context": {"desired_experience": "exciting"}},
        headers=v.headers | {"Idempotency-Key": str(uuid.uuid4())},
    )
    assert r.status_code == 201
    assert movies.availability_calls == [], "availability is display-only"


@pytest.mark.integration
def test_cache_is_shared_metadata_not_private(
    v: Viewer, client: TestClient, signer: Signer, movies: FakeMovieProvider, engine: Engine
) -> None:
    v.set(country_code="IN")
    v.availability()
    other = Viewer(client, signer)
    other.set(country_code="US")
    assert [p["name"] for p in other.availability().json()["streaming"]] == ["Amazon Prime Video"]
    assert movies.availability_calls == [LOLA], "one fetch serves every region and user"
    assert (
        scalar(engine, "SELECT count(*) FROM cineme.movies WHERE watch_providers IS NOT NULL") == 1
    )
