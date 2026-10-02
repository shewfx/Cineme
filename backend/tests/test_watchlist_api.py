"""Search, movie details and the per-user watchlist on real PostgreSQL, with
a scripted metadata provider (no TMDB network)."""

import threading
import uuid
from datetime import UTC, date, datetime, timedelta
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlalchemy.engine import Engine
from sqlalchemy.exc import IntegrityError

from app.watchlist import service as watchlist_service
from tests.conftest import FakeMovieProvider, Signer, film

pytestmark = pytest.mark.integration


class Api:
    """A signed-in user with a bootstrapped profile."""

    def __init__(self, client: TestClient, signer: Signer) -> None:
        self.client = client
        self.id = uuid.uuid4()
        self.headers = {"Authorization": f"Bearer {signer.token(self.id)}"}
        assert client.post("/api/v1/me/bootstrap", headers=self.headers).status_code == 201

    def search(self, q: str) -> Any:
        return self.client.get("/api/v1/movies/search", params={"q": q}, headers=self.headers)

    def add(self, tmdb_id: int, key: str | None = None) -> Any:
        return self.client.post(
            "/api/v1/watchlist",
            json={"tmdb_id": tmdb_id},
            headers=self.headers | {"Idempotency-Key": key or str(uuid.uuid4())},
        )

    def remove(self, entry_id: str, key: str | None = None) -> Any:
        return self.client.delete(
            f"/api/v1/watchlist/{entry_id}",
            headers=self.headers | {"Idempotency-Key": key or str(uuid.uuid4())},
        )

    def entries(self, **params: Any) -> Any:
        return self.client.get("/api/v1/watchlist", params=params, headers=self.headers)

    def titles(self) -> list[str]:
        return [i["movie"]["title"] for i in self.entries().json()["items"]]


@pytest.fixture
def a(client: TestClient, signer: Signer) -> Api:
    return Api(client, signer)


@pytest.fixture
def b(client: TestClient, signer: Signer) -> Api:
    return Api(client, signer)


def scalar(engine: Engine, sql: str, **params: Any) -> Any:
    with engine.connect() as conn:
        return conn.execute(text(sql), params).scalar()


# --- search and details ---------------------------------------------------------


def test_search_returns_cinemé_shapes_with_unknowns_null(a: Api) -> None:
    body = a.search("run").json()
    (lola,) = body["results"]
    assert lola == {
        "tmdb_id": 104,
        "title": "Run Lola Run",
        "year": 2000,
        "runtime_minutes": None,  # not cached yet: never fetched per result
        "genre_ids": [28, 18],
        "genres": [{"id": 28, "name": "Action"}, {"id": 18, "name": "Drama"}],
        "poster_url": "https://image.tmdb.org/t/p/w500/p104.jpg",
        "can_add": True,
        "released": True,
    }


def test_search_separates_saving_from_release(a: Api) -> None:
    results = {r["title"]: r for r in a.search("film").json()["results"]}
    assert results["Future Film"]["can_add"] is True
    assert results["Future Film"]["released"] is False
    assert results["Undated Film"]["can_add"] is True
    assert results["Undated Film"]["released"] is False
    assert results["Undated Film"]["year"] is None
    assert results["Adult Film"]["can_add"] is False


def test_search_shows_runtime_once_details_are_cached(a: Api) -> None:
    a.add(104)
    assert a.search("run").json()["results"][0]["runtime_minutes"] == 81


def test_missing_poster_is_null(a: Api) -> None:
    assert a.search("primer").json()["results"][0]["poster_url"] is None


@pytest.mark.parametrize("params", [{"q": "a"}, {"q": "x" * 101}, {"q": "ok", "page": 0}])
def test_search_validation(a: Api, params: dict[str, Any]) -> None:
    response = a.client.get("/api/v1/movies/search", params=params, headers=a.headers)
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"


def test_search_upstream_failure_is_visible(a: Api, movies: FakeMovieProvider) -> None:
    movies.down = True
    response = a.search("run")
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "DEPENDENCY_UNAVAILABLE"
    assert response.headers["X-Request-ID"]


def test_movie_endpoints_require_auth_and_a_profile(client: TestClient, signer: Signer) -> None:
    assert client.get("/api/v1/movies/search", params={"q": "run"}).status_code == 401
    assert client.get("/api/v1/watchlist").status_code == 401
    stranger = {"Authorization": f"Bearer {signer.token(uuid.uuid4())}"}
    response = client.get("/api/v1/movies/search", params={"q": "run"}, headers=stranger)
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "PROFILE_NOT_INITIALIZED"


def test_details_cache_and_stale_fallback(
    a: Api, movies: FakeMovieProvider, engine: Engine
) -> None:
    first = a.client.get("/api/v1/movies/329865", headers=a.headers).json()
    assert first["runtime_minutes"] == 116
    assert first["stale"] is False
    assert first["traits"] == {"pace": None, "complexity": None, "heaviness": None, "source": None}
    assert first["vote_average"] == 7.0 and first["original_language"] == "en"
    a.client.get("/api/v1/movies/329865", headers=a.headers)
    assert movies.detail_calls == [329865], "fresh cache is reused"

    with engine.begin() as conn:
        conn.execute(
            text("UPDATE cineme.movies SET fetched_at = :t WHERE tmdb_id = 329865"),
            {"t": datetime.now(UTC) - timedelta(days=8)},
        )
    movies.down = True
    stale = a.client.get("/api/v1/movies/329865", headers=a.headers).json()
    assert stale["stale"] is True and stale["title"] == "Arrival"

    unknown = a.client.get("/api/v1/movies/424242", headers=a.headers)
    assert unknown.status_code == 503, "no usable prior row during an outage"


def test_details_unknown_film_is_404(a: Api) -> None:
    assert a.client.get("/api/v1/movies/424242", headers=a.headers).status_code == 404


# --- add / list / remove ------------------------------------------------------------


def test_add_then_duplicate_add_returns_the_same_entry(a: Api, engine: Engine) -> None:
    first = a.add(104)
    assert first.status_code == 201
    entry = first.json()["entry"]
    assert first.json()["already_present"] is False
    assert entry["movie"]["runtime_minutes"] == 81
    assert entry["source_type"] == "manual"

    again = a.add(104)
    assert again.status_code == 200
    assert again.json()["already_present"] is True
    assert again.json()["entry"]["id"] == entry["id"]
    assert scalar(engine, "SELECT count(*) FROM cineme.watchlist_entries") == 1


def test_list_is_newest_first_and_paginates(a: Api) -> None:
    for tmdb_id in (104, 329865, 14337):
        a.add(tmdb_id)
    page1 = a.entries(limit=2).json()
    assert [i["movie"]["title"] for i in page1["items"]] == ["Primer", "Arrival"]
    page2 = a.entries(limit=2, cursor=page1["next_cursor"]).json()
    assert [i["movie"]["title"] for i in page2["items"]] == ["Run Lola Run"]
    assert page2["next_cursor"] is None
    assert a.entries(q="arr").json()["items"][0]["movie"]["title"] == "Arrival"
    assert a.entries(q="%").json()["items"] == [], "LIKE wildcards are escaped"
    assert a.entries(cursor="not-a-cursor").status_code == 422


def test_remove_archives_and_restore_resets_age(a: Api, engine: Engine) -> None:
    entry = a.add(104).json()["entry"]
    removed = a.remove(entry["id"]).json()
    assert removed["removed"] is True
    assert removed["today"]["state"] == "empty_watchlist"
    assert a.titles() == []
    assert a.remove(entry["id"]).status_code == 200, "already removed succeeds"
    assert scalar(engine, "SELECT status FROM cineme.watchlist_entries") == "removed"

    restored = a.add(104)
    assert restored.status_code == 201
    assert restored.json()["entry"]["id"] == entry["id"], "same row, history kept"
    assert restored.json()["entry"]["added_at"] > entry["added_at"]
    assert a.titles() == ["Run Lola Run"]


def test_adult_films_are_rejected_and_never_stored(a: Api, engine: Engine) -> None:
    response = a.add(890)
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "MOVIE_INELIGIBLE"
    assert scalar(engine, "SELECT count(*) FROM cineme.watchlist_entries") == 0
    assert scalar(engine, "SELECT count(*) FROM cineme.movies WHERE tmdb_id = 890") == 0


@pytest.mark.parametrize(("tmdb_id", "date_sql"), [(888, "2999-01-01"), (889, None)])
def test_upcoming_and_undated_films_are_saved_but_not_released(
    a: Api, engine: Engine, tmdb_id: int, date_sql: str | None
) -> None:
    response = a.add(tmdb_id)
    assert response.status_code == 201
    assert response.json()["entry"]["movie"]["released"] is False
    (item,) = a.entries().json()["items"]
    assert item["movie"]["released"] is False
    # The date P4 needs to enforce eligibility is preserved as-is (unknown stays null).
    stored = scalar(
        engine, "SELECT release_date::text FROM cineme.movies WHERE tmdb_id = :i", i=tmdb_id
    )
    assert stored == date_sql


def test_undated_film_becomes_released_once_metadata_establishes_a_date(
    a: Api, movies: FakeMovieProvider, engine: Engine
) -> None:
    entry = a.add(889).json()["entry"]
    with engine.begin() as conn:
        conn.execute(
            text("UPDATE cineme.movies SET fetched_at = :t"),
            {"t": datetime.now(UTC) - timedelta(days=8)},
        )
    movies.films[889] = film(889, "Undated Film", release_date=date(2001, 5, 4))
    assert a.client.get("/api/v1/movies/889", headers=a.headers).json()["released"] is True
    (item,) = a.entries().json()["items"]
    assert item["id"] == entry["id"] and item["movie"]["released"] is True


def test_unknown_film_is_404(a: Api) -> None:
    assert a.add(424242).status_code == 404


def test_upstream_outage_on_first_add_is_503_and_saves_nothing(
    a: Api, movies: FakeMovieProvider, engine: Engine
) -> None:
    movies.down = True
    assert a.add(104).status_code == 503
    assert scalar(engine, "SELECT count(*) FROM cineme.watchlist_entries") == 0


def test_saved_list_works_while_tmdb_is_down(a: Api, movies: FakeMovieProvider) -> None:
    a.add(104)
    movies.down = True
    response = a.entries()
    assert response.status_code == 200
    assert [i["movie"]["title"] for i in response.json()["items"]] == ["Run Lola Run"]
    assert response.json()["items"][0]["movie"]["genres"] == [], "names optional when down"


def test_active_limit_is_enforced(a: Api, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(watchlist_service, "ACTIVE_LIMIT", 2)
    assert a.add(104).status_code == 201
    assert a.add(329865).status_code == 201
    full = a.add(14337)
    assert full.status_code == 409
    assert full.json()["error"]["code"] == "WATCHLIST_LIMIT"
    assert a.add(104).status_code == 200, "a duplicate is not a new entry"


def test_watchlist_changes_never_touch_preferences(a: Api, engine: Engine) -> None:
    before = scalar(
        engine,
        "SELECT version FROM cineme.user_preferences WHERE user_id = :u",
        u=a.id,
    )
    entry = a.add(104).json()["entry"]
    a.remove(entry["id"])
    after = scalar(
        engine,
        "SELECT row(version, genre_preferences, blocked_genre_ids)::text "
        "FROM cineme.user_preferences WHERE user_id = :u",
        u=a.id,
    )
    assert before == 1
    assert after == "(1,{},{})"


def test_metadata_refresh_does_not_alter_entries(
    a: Api, b: Api, movies: FakeMovieProvider, engine: Engine
) -> None:
    entry = a.add(329865).json()["entry"]
    with engine.begin() as conn:
        conn.execute(
            text("UPDATE cineme.movies SET fetched_at = :t"),
            {"t": datetime.now(UTC) - timedelta(days=8)},
        )
    movies.films[329865] = film(329865, "Arrival (2016)", runtime_minutes=118)
    b.add(329865)  # refreshes the shared cache
    item = a.entries().json()["items"][0]
    assert item["id"] == entry["id"] and item["added_at"] == entry["added_at"]
    assert item["movie"]["title"] == "Arrival (2016)"
    assert item["movie"]["runtime_minutes"] == 118


# --- ownership and identity ------------------------------------------------------------


def test_users_never_see_or_change_each_others_watchlists(a: Api, b: Api, engine: Engine) -> None:
    a_entry = a.add(104).json()["entry"]
    b.add(329865)

    assert a.titles() == ["Run Lola Run"]
    assert b.titles() == ["Arrival"]

    stolen = b.remove(a_entry["id"])
    assert stolen.status_code == 404, "another user's entry looks like it doesn't exist"
    assert a.titles() == ["Run Lola Run"]

    # Same film for both users: two independent entries.
    shared = b.add(104).json()["entry"]
    assert shared["id"] != a_entry["id"]
    b.remove(shared["id"])
    assert a.titles() == ["Run Lola Run"]
    assert scalar(engine, "SELECT count(*) FROM cineme.watchlist_entries") == 3


def test_client_cannot_supply_an_owner(a: Api, b: Api) -> None:
    response = a.client.post(
        "/api/v1/watchlist",
        json={"tmdb_id": 104, "user_id": str(b.id)},
        headers=a.headers | {"Idempotency-Key": str(uuid.uuid4())},
    )
    assert response.status_code == 422
    assert b.titles() == []


@pytest.mark.parametrize("token", [None, "Bearer junk"])
def test_watchlist_mutations_require_a_valid_token(client: TestClient, token: str | None) -> None:
    headers = {"Idempotency-Key": str(uuid.uuid4())}
    if token:
        headers["Authorization"] = token
    assert (
        client.post("/api/v1/watchlist", json={"tmdb_id": 104}, headers=headers).status_code == 401
    )
    assert client.delete(f"/api/v1/watchlist/{uuid.uuid4()}", headers=headers).status_code == 401


# --- idempotency ----------------------------------------------------------------------------


def test_add_requires_an_idempotency_key(a: Api) -> None:
    response = a.client.post("/api/v1/watchlist", json={"tmdb_id": 104}, headers=a.headers)
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "IDEMPOTENCY_KEY_REQUIRED"


def test_add_replay_and_conflict(a: Api, movies: FakeMovieProvider) -> None:
    key = str(uuid.uuid4())
    first = a.add(104, key)
    movies.down = True  # a replay needs no network
    replay = a.add(104, key)
    assert replay.status_code == 201
    assert replay.json() == first.json()
    conflict = a.add(329865, key)
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "IDEMPOTENCY_CONFLICT"


def test_remove_replay_does_not_undo_a_later_restore(a: Api) -> None:
    entry = a.add(104).json()["entry"]
    key = str(uuid.uuid4())
    first = a.remove(entry["id"], key).json()
    a.add(104)
    assert a.remove(entry["id"], key).json() == first, "replays the stored response"
    assert a.titles() == ["Run Lola Run"], "the replay returned the old result only"


def test_parallel_duplicate_adds_create_one_entry(a: Api, engine: Engine) -> None:
    results: list[int] = []
    barrier = threading.Barrier(6)

    def run() -> None:
        barrier.wait()
        results.append(a.add(104).status_code)

    threads = [threading.Thread(target=run) for _ in range(6)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(results) == [200] * 5 + [201]
    assert scalar(engine, "SELECT count(*) FROM cineme.watchlist_entries") == 1


# --- database constraints -----------------------------------------------------------------


@pytest.mark.parametrize(
    "statement",
    [
        "UPDATE cineme.watchlist_entries SET status = 'removed'",  # removed_at missing
        "UPDATE cineme.watchlist_entries SET removed_at = now()",  # active with removed_at
        "UPDATE cineme.watchlist_entries SET status = 'deleted', removed_at = now()",
        "UPDATE cineme.watchlist_entries SET source_type = 'scraped'",
        "INSERT INTO cineme.watchlist_entries (id, user_id, movie_id, added_at) "
        "SELECT gen_random_uuid(), user_id, movie_id, now() FROM cineme.watchlist_entries",
        "UPDATE cineme.movies SET runtime_minutes = 0",
        "UPDATE cineme.movies SET vote_average = 10.5",
        "UPDATE cineme.movies SET poster_path = 'https://evil.example/x.jpg'",
        "UPDATE cineme.movies SET metadata_status = 'maybe'",
        "DELETE FROM cineme.movies",  # still referenced by a watchlist entry
    ],
)
def test_constraints(a: Api, engine: Engine, statement: str) -> None:
    a.add(104)
    with pytest.raises(IntegrityError), engine.begin() as conn:
        conn.execute(text(statement))
