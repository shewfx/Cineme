"""Shows and anime on real PostgreSQL with a scripted TMDB (ADR 011): series
metadata, the union watchlist and its media filter, progress and episode
watches, blocks, and Tonight's media preference with next-episode picks and
series continuity."""

import threading
import uuid
from datetime import UTC, date, datetime, timedelta
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlalchemy.engine import Engine

from app.series import service as series_service
from app.watchlist import service as watchlist_service
from tests.conftest import FakeMovieProvider, Signer, episodes_for, film, tv
from tests.test_today_api import Tonight, ctx
from tests.test_watchlist_api import scalar

pytestmark = pytest.mark.integration

ALPHA, BETA, GAMMA = 1399, 1400, 1401
FEATURES = {"X-Cineme-Features": "series-v1"}


class Shows(Tonight):
    """A signed-in user on a client that declares series support."""

    def __init__(self, client: TestClient, signer: Signer, *, features: bool = True) -> None:
        super().__init__(client, signer)
        if features:
            self.headers = self.headers | FEATURES

    def legacy(self) -> dict[str, str]:
        """The same user as an older client (no capability header)."""
        return {k: v for k, v in self.headers.items() if k not in FEATURES}

    def key(self) -> dict[str, str]:
        return {"Idempotency-Key": str(uuid.uuid4())}

    def add_series(self, tmdb_id: int, key: str | None = None) -> Any:
        headers = self.headers | {"Idempotency-Key": key or str(uuid.uuid4())}
        return self.client.post(
            "/api/v1/watchlist", json={"media_type": "series", "tmdb_id": tmdb_id}, headers=headers
        )

    def listing(self, headers: dict[str, str] | None = None, **params: Any) -> dict[str, Any]:
        r = self.client.get("/api/v1/watchlist", params=params, headers=headers or self.headers)
        assert r.status_code == 200, r.text
        body: dict[str, Any] = r.json()
        return body

    def details(self, tmdb_id: int) -> dict[str, Any]:
        r = self.client.get(f"/api/v1/tv/{tmdb_id}", headers=self.headers)
        assert r.status_code == 200, r.text
        body: dict[str, Any] = r.json()
        return body

    def entry(self, tmdb_id: int) -> dict[str, Any]:
        entry = self.details(tmdb_id)["entry"]
        assert entry is not None
        out: dict[str, Any] = entry
        return out

    def set_progress(
        self, tmdb_id: int, version: int, last: tuple[int, int] | None, key: str | None = None
    ) -> Any:
        body = {
            "expected_version": version,
            "last_watched": None if last is None else {"season": last[0], "episode": last[1]},
        }
        headers = self.headers | {"Idempotency-Key": key or str(uuid.uuid4())}
        return self.client.put(f"/api/v1/series/{tmdb_id}/progress", json=body, headers=headers)

    def mark(self, tmdb_id: int, season: int, episode: int, **kw: Any) -> Any:
        body = {"season": season, "episode": episode} | kw
        return self.client.post(
            f"/api/v1/series/{tmdb_id}/episodes/watched",
            json=body,
            headers=self.headers | self.key(),
        )

    def set_media(self, media: str) -> Any:
        me = self.client.get("/api/v1/me", headers=self.headers).json()
        body = {"expected_version": me["preferences"]["version"], "tonight_media": media}
        return self.client.patch(
            "/api/v1/me/preferences", json=body, headers=self.headers | self.key()
        )

    def today(self, headers: dict[str, str] | None = None) -> dict[str, Any]:
        r = self.client.get("/api/v1/today", headers=headers or self.headers)
        assert r.status_code == 200
        body: dict[str, Any] = r.json()
        return body


@pytest.fixture
def a(client: TestClient, signer: Signer) -> Shows:
    return Shows(client, signer)


@pytest.fixture
def b(client: TestClient, signer: Signer) -> Shows:
    return Shows(client, signer)


@pytest.fixture
def shows(movies: FakeMovieProvider) -> FakeMovieProvider:
    movies.series[ALPHA] = tv(ALPHA, "Alpha", genre_ids=(18,), seasons=((1, 3), (2, 2)))
    movies.episodes[ALPHA] = episodes_for(((1, 3), (2, 2)))
    movies.series[BETA] = tv(BETA, "Beta", genre_ids=(18,))
    movies.episodes[BETA] = episodes_for(((1, 3),))
    movies.series[GAMMA] = tv(GAMMA, "Gamma", genre_ids=(10759,), status="Ended", seasons=((1, 2),))
    movies.episodes[GAMMA] = episodes_for(((1, 2),))
    return movies


def state(entry: dict[str, Any]) -> str:
    out: str = entry["next"]["state"]
    return out


def next_ep(entry: dict[str, Any]) -> tuple[int, int] | None:
    ep = entry["next"]["episode"]
    return None if ep is None else (ep["season_number"], ep["episode_number"])


# --- S1: metadata --------------------------------------------------------------


def test_tv_search_details_and_seasons_use_cinemé_shapes(
    a: Shows, shows: FakeMovieProvider
) -> None:
    found = a.client.get("/api/v1/tv/search", params={"q": "alp"}, headers=a.headers).json()
    assert [r["name"] for r in found["results"]] == ["Alpha"]
    assert set(found["results"][0]) >= {
        "tmdb_id",
        "name",
        "year",
        "status",
        "poster_url",
        "can_add",
    }

    d = a.details(ALPHA)
    assert d["series"]["name"] == "Alpha" and d["series"]["year"] == 2015
    assert d["season_count"] == 2 and d["stale"] is False and d["entry"] is None
    assert "Specials aren't included" in d["limitations"]

    seasons = a.client.get(f"/api/v1/tv/{ALPHA}/seasons", headers=a.headers).json()
    assert [s["season_number"] for s in seasons["seasons"]] == [1, 2]
    assert [e["episode_number"] for e in seasons["seasons"][0]["episodes"]] == [1, 2, 3]
    assert a.client.get("/api/v1/tv/999999", headers=a.headers).status_code == 404
    assert a.client.get("/api/v1/tv/search?q=a", headers=a.headers).status_code == 422
    assert a.client.get("/api/v1/tv/search?q=alp").status_code == 401


def test_series_metadata_is_cached_and_stale_when_tmdb_is_down(
    a: Shows, shows: FakeMovieProvider, engine: Engine
) -> None:
    a.details(ALPHA)
    a.details(ALPHA)
    assert shows.tv_detail_calls == [ALPHA], "fresh cache: no second fetch"
    with engine.begin() as conn:
        conn.execute(text("UPDATE cineme.series SET fetched_at = now() - interval '3 days'"))
    shows.down = True
    stale = a.details(ALPHA)
    assert stale["stale"] is True and stale["series"]["name"] == "Alpha"
    unknown = a.client.get("/api/v1/tv/1400", headers=a.headers)
    assert unknown.status_code == 503, "never cached: the failure is visible"


def test_adult_series_are_never_stored(a: Shows, shows: FakeMovieProvider, engine: Engine) -> None:
    shows.series[7] = tv(7, "Adult Show", adult=True)
    assert a.add_series(7).status_code == 422
    assert scalar(engine, "SELECT count(*) FROM cineme.series WHERE tmdb_id = 7") == 0


# --- S2: the watchlist with shows ----------------------------------------------


def test_adding_a_series_is_explicit_idempotent_and_leaves_movies_alone(
    a: Shows, shows: FakeMovieProvider
) -> None:
    first = a.add_series(ALPHA)
    assert first.status_code == 201
    entry = first.json()["entry"]
    assert entry["media_type"] == "series" and entry["series"]["tmdb_id"] == ALPHA
    assert state(entry) == "up_next" and next_ep(entry) == (1, 1) and entry["progress"] is None
    again = a.add_series(ALPHA)
    assert again.status_code == 200 and again.json()["already_present"] is True
    key = str(uuid.uuid4())
    one, two = a.add_series(BETA, key), a.add_series(BETA, key)
    assert (one.status_code, two.status_code) == (201, 201)
    assert one.json() == two.json(), "same key replays"
    # A movie request with no media_type is unchanged and cannot collide: TV and
    # movie ids overlap, so the same number means two different things.
    shows.films[ALPHA] = film(ALPHA, "A Film With The Same Id")
    assert a.add(ALPHA).status_code == 201
    titles = [
        (i["media_type"], i.get("movie", i.get("series"))["tmdb_id"]) for i in a.listing()["items"]
    ]
    assert sorted(titles) == sorted([("movie", ALPHA), ("series", ALPHA), ("series", BETA)])


def test_media_filter_lists_movies_shows_or_everything(a: Shows, shows: FakeMovieProvider) -> None:
    assert a.add(104).status_code == 201
    assert a.add_series(ALPHA).status_code == 201
    kinds = lambda **p: sorted(i["media_type"] for i in a.listing(**p)["items"])  # noqa: E731
    assert kinds() == ["movie", "series"]  # default for a capable client: all
    assert kinds(media="all") == ["movie", "series"]
    assert kinds(media="movies") == ["movie"]
    assert kinds(media="shows") == ["series"]
    assert a.client.get("/api/v1/watchlist?media=tv", headers=a.headers).status_code == 422


def test_older_clients_keep_the_movie_only_contract(a: Shows, shows: FakeMovieProvider) -> None:
    a.add(104)
    a.add_series(ALPHA)
    legacy = a.listing(headers=a.legacy())
    assert [i["media_type"] for i in legacy["items"]] == ["movie"]
    assert all("series" not in i for i in legacy["items"])
    forced = a.listing(headers=a.legacy(), media="shows")
    assert [i["media_type"] for i in forced["items"]] == ["movie"], "the filter is ignored"


@pytest.mark.parametrize(
    "sort",
    ["added_desc", "added_asc", "title_asc", "title_desc", "year_desc", "year_asc", "runtime_asc"],
)
def test_union_paging_equals_the_full_list_in_every_sort(
    a: Shows, shows: FakeMovieProvider, sort: str
) -> None:
    for i in range(4):
        shows.films[600 + i] = film(600 + i, f"Movie {i}", release_date=date(1990 + i, 1, 1))
        assert a.add(600 + i).status_code == 201
    for sid in (ALPHA, BETA, GAMMA):
        assert a.add_series(sid).status_code == 201
    full = a.listing(sort=sort, limit=50)
    assert len(full["items"]) == 7 and full["next_cursor"] is None
    seen: list[str] = []
    cursor = None
    for _ in range(10):
        page = a.listing(sort=sort, limit=2, **({"cursor": cursor} if cursor else {}))
        seen += [i["id"] for i in page["items"]]
        cursor = page["next_cursor"]
        if cursor is None:
            break
    assert seen == [i["id"] for i in full["items"]], "pages never reorder or repeat"
    assert len(set(seen)) == 7


def test_search_filter_and_cursor_belong_to_the_union(a: Shows, shows: FakeMovieProvider) -> None:
    a.add(104)
    a.add_series(ALPHA)
    hits = a.listing(q="alp")["items"]
    assert [i["series"]["name"] for i in hits] == ["Alpha"]
    cursor = a.listing(limit=1, sort="title_asc")["next_cursor"]
    bad = a.client.get(
        "/api/v1/watchlist", params={"cursor": cursor, "sort": "added_desc"}, headers=a.headers
    )
    assert bad.status_code == 422


def test_removing_and_re_adding_a_show_keeps_progress(
    a: Shows, shows: FakeMovieProvider, engine: Engine
) -> None:
    entry_id = a.add_series(ALPHA).json()["entry"]["id"]
    assert a.mark(ALPHA, 1, 1).status_code == 200
    removed = a.client.delete(f"/api/v1/watchlist/{entry_id}", headers=a.headers | a.key())
    assert removed.status_code == 200 and removed.json()["removed"] is True
    assert a.listing(media="shows")["items"] == []
    again = a.add_series(ALPHA)
    assert again.status_code == 201
    assert again.json()["entry"]["id"] == entry_id, "the archived row is restored"
    assert again.json()["entry"]["progress"]["season"] == 1
    assert next_ep(again.json()["entry"]) == (1, 2)
    assert scalar(engine, "SELECT count(*) FROM cineme.episode_viewings") == 1


def test_shows_are_private(a: Shows, b: Shows, shows: FakeMovieProvider) -> None:
    entry_id = a.add_series(ALPHA).json()["entry"]["id"]
    assert b.listing(media="shows")["items"] == []
    assert (
        b.client.delete(f"/api/v1/watchlist/{entry_id}", headers=b.headers | b.key()).status_code
        == 404
    )
    assert b.set_progress(ALPHA, 1, (1, 1)).status_code == 404
    assert b.mark(ALPHA, 1, 1).status_code == 404
    assert b.details(ALPHA)["entry"] is None, "B sees the show but not A's entry"
    assert a.entry(ALPHA)["progress"] is None


def test_the_combined_watchlist_cap_counts_movies_and_shows(
    a: Shows, shows: FakeMovieProvider, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(series_service, "ACTIVE_LIMIT", 2)
    monkeypatch.setattr(watchlist_service, "ACTIVE_LIMIT", 2)
    assert a.add(104).status_code == 201
    assert a.add_series(ALPHA).status_code == 201
    full = a.add_series(BETA)
    assert full.status_code == 409 and full.json()["error"]["code"] == "WATCHLIST_LIMIT"
    assert a.add(329865).status_code == 409


# --- S3: progress and episode history ------------------------------------------


def test_next_episode_states(a: Shows, shows: FakeMovieProvider, engine: Engine) -> None:
    a.add_series(ALPHA)
    a.add_series(GAMMA)  # ended
    e = a.entry(ALPHA)
    assert (state(e), next_ep(e)) == ("up_next", (1, 1))
    # Mid-season and across a season boundary.
    assert a.set_progress(ALPHA, e["progress_version"], (1, 3)).status_code == 200
    assert next_ep(a.entry(ALPHA)) == (2, 1)
    v = a.entry(ALPHA)["progress_version"]
    assert a.set_progress(ALPHA, v, (2, 2)).status_code == 200
    assert state(a.entry(ALPHA)) == "caught_up", "a returning show with nothing newer"
    g = a.entry(GAMMA)
    assert a.set_progress(GAMMA, g["progress_version"], (1, 2)).status_code == 200
    assert state(a.entry(GAMMA)) == "completed", "an ended show with nothing newer"
    # An episode that has not aired is never offered, and nothing after it is.
    future = date.today() + timedelta(days=30)
    shows.series[BETA] = tv(BETA, "Beta", genre_ids=(18,))
    shows.episodes[BETA] = episodes_for(((1, 1),)) + tuple(
        replace_air(e, future) for e in episodes_for(((1, 3),), air=future)[1:]
    )
    a.add_series(BETA)
    b_entry = a.entry(BETA)
    assert a.set_progress(BETA, b_entry["progress_version"], (1, 1)).status_code == 200
    waiting = a.entry(BETA)
    assert state(waiting) == "not_aired" and next_ep(waiting) == (1, 2)
    assert waiting["next"]["episode"]["air_date"] == future.isoformat()
    # No episode data at all: unavailable, not caught up.
    with engine.begin() as conn:
        conn.execute(
            text("UPDATE cineme.series SET episodes_fetched_at = NULL WHERE tmdb_id = :i"),
            {"i": ALPHA},
        )
    listed = {i["series"]["tmdb_id"]: i for i in a.listing(media="shows")["items"]}
    assert state(listed[ALPHA]) == "unavailable"


def replace_air(episode: Any, air: date) -> Any:
    from dataclasses import replace

    return replace(episode, air_date=air)


def test_setting_progress_is_validated_versioned_and_creates_no_history(
    a: Shows, shows: FakeMovieProvider, engine: Engine
) -> None:
    a.add_series(ALPHA)
    v = a.entry(ALPHA)["progress_version"]
    assert a.set_progress(ALPHA, v, (9, 9)).json()["error"]["code"] == "EPISODE_NOT_FOUND"
    assert a.set_progress(ALPHA, v, (0, 1)).status_code == 422
    key = str(uuid.uuid4())
    ok = a.set_progress(ALPHA, v, (1, 2), key)
    assert ok.status_code == 200
    assert ok.json()["entry"]["progress"] == {"season": 1, "episode": 2, "version": v + 1}
    replay = a.set_progress(ALPHA, v, (1, 2), key)
    assert replay.status_code == 200 and replay.json() == ok.json()
    stale = a.set_progress(ALPHA, v, (1, 3))
    assert stale.status_code == 409
    assert stale.json()["error"]["code"] == "VERSION_CONFLICT"
    assert stale.json()["error"]["details"]["current_version"] == v + 1
    # Correcting backwards and clearing both work, and neither writes a viewing.
    assert a.set_progress(ALPHA, v + 1, (1, 1)).status_code == 200
    assert a.set_progress(ALPHA, v + 2, None).status_code == 200
    assert a.entry(ALPHA)["progress"] is None
    assert scalar(engine, "SELECT count(*) FROM cineme.episode_viewings") == 0


def test_an_unaired_episode_cannot_be_set_as_progress(a: Shows, shows: FakeMovieProvider) -> None:
    future = date.today() + timedelta(days=9)
    shows.episodes[ALPHA] = episodes_for(((1, 1),)) + episodes_for(((1, 2),), air=future)[1:]
    a.add_series(ALPHA)
    v = a.entry(ALPHA)["progress_version"]
    r = a.set_progress(ALPHA, v, (1, 2))
    assert r.status_code == 422 and r.json()["error"]["code"] == "EPISODE_NOT_AIRED"


def test_mark_watched_advances_progress_once_and_never_skips_ahead(
    a: Shows, shows: FakeMovieProvider, engine: Engine
) -> None:
    a.add_series(ALPHA)
    skip = a.mark(ALPHA, 1, 3)
    assert skip.status_code == 409 and skip.json()["error"]["code"] == "NOT_NEXT_EPISODE"
    assert skip.json()["error"]["details"]["next"] == {"season_number": 1, "episode_number": 1}
    assert scalar(engine, "SELECT count(*) FROM cineme.episode_viewings") == 0

    first = a.mark(ALPHA, 1, 1, rating=4)
    assert first.status_code == 200
    body = first.json()
    assert body["already_recorded"] is False and body["viewing"]["rating"] == 4
    assert body["entry"]["progress"]["episode"] == 1 and next_ep(body["entry"]) == (1, 2)
    again = a.mark(ALPHA, 1, 1)
    assert again.status_code == 200 and again.json()["already_recorded"] is True
    assert a.entry(ALPHA)["progress"]["version"] == body["entry"]["progress"]["version"]
    assert scalar(engine, "SELECT count(*) FROM cineme.episode_viewings") == 1


def test_concurrent_devices_marking_the_same_episode_record_it_once(
    a: Shows, shows: FakeMovieProvider, engine: Engine
) -> None:
    a.add_series(ALPHA)
    results: list[int] = []

    def go() -> None:
        results.append(a.mark(ALPHA, 1, 1).status_code)

    threads = [threading.Thread(target=go) for _ in range(5)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert results == [200] * 5
    assert scalar(engine, "SELECT count(*) FROM cineme.episode_viewings") == 1
    entry = a.entry(ALPHA)
    assert entry["progress"]["season"] == 1 and entry["progress"]["episode"] == 1
    assert next_ep(entry) == (1, 2), "advanced exactly once"


def test_a_manual_correction_after_a_watch_does_not_double_count(
    a: Shows, shows: FakeMovieProvider
) -> None:
    a.add_series(ALPHA)
    a.mark(ALPHA, 1, 1)
    a.mark(ALPHA, 1, 2)
    v = a.entry(ALPHA)["progress"]["version"]
    assert a.set_progress(ALPHA, v, (1, 1)).status_code == 200  # "I hadn't seen 2 yet"
    assert next_ep(a.entry(ALPHA)) == (1, 2)
    again = a.mark(ALPHA, 1, 2)
    assert again.status_code == 200 and again.json()["already_recorded"] is True
    assert next_ep(a.entry(ALPHA)) == (1, 2) or a.entry(ALPHA)["progress"]["episode"] == 2


def test_episode_and_series_ratings_are_separate_and_versioned(
    a: Shows, shows: FakeMovieProvider
) -> None:
    a.add_series(ALPHA)
    viewing = a.mark(ALPHA, 1, 1).json()["viewing"]
    assert viewing["version"] == 1 and viewing["rating"] is None
    patch = lambda body: a.client.patch(  # noqa: E731
        f"/api/v1/episode-viewings/{viewing['id']}", json=body, headers=a.headers | a.key()
    )
    ok = patch({"expected_version": 1, "rating": 5})
    assert ok.status_code == 200 and ok.json()["viewing"]["version"] == 2
    assert patch({"expected_version": 1, "rating": 2}).status_code == 409
    assert patch({"expected_version": 2, "rating": 6}).status_code == 422
    rated = a.client.patch(
        f"/api/v1/series/{ALPHA}/rating", json={"rating": 3}, headers=a.headers | a.key()
    )
    assert rated.status_code == 200 and rated.json()["entry"]["series_rating"] == 3
    assert ok.json()["viewing"]["rating"] == 5, "the episode rating is its own record"


def test_blocking_a_show_is_reversible_and_blocks_adding(
    a: Shows, shows: FakeMovieProvider
) -> None:
    blocked = a.client.post(f"/api/v1/me/blocks/series/{ALPHA}", headers=a.headers | a.key())
    assert blocked.status_code == 200 and blocked.json()["already_blocked"] is False
    refused = a.add_series(ALPHA)
    assert refused.status_code == 409 and refused.json()["error"]["code"] == "SERIES_BLOCKED"
    listed = a.client.get("/api/v1/me/blocks/series", headers=a.headers).json()
    assert [i["series"]["tmdb_id"] for i in listed["items"]] == [ALPHA]
    assert (
        a.client.delete(
            f"/api/v1/me/blocks/series/{ALPHA}", headers=a.headers | a.key()
        ).status_code
        == 200
    )
    assert a.add_series(ALPHA).status_code == 201


# --- S4: Tonight ---------------------------------------------------------------


def test_the_default_preference_is_movies_only_for_everyone(
    a: Shows, shows: FakeMovieProvider
) -> None:
    me = a.client.get("/api/v1/me", headers=a.headers).json()
    assert me["preferences"]["tonight_media"] == "movies"
    a.add_series(ALPHA)
    env = a.today()
    assert env["state"] == "empty_watchlist" and env["empty_reason"] == "no_movies"
    assert env["media"] == "movies"
    r = a.choose(ctx())
    assert r.json()["state"] != "offered" or r.json()["recommendation"]["media_kind"] == "movie"


def test_shows_only_offers_the_next_episode_and_nothing_else(
    a: Shows, shows: FakeMovieProvider, engine: Engine
) -> None:
    a.add(104)
    a.add_series(ALPHA)
    assert a.set_media("shows").status_code == 200
    r = a.choose(ctx())
    assert r.status_code == 201
    rec = r.json()["recommendation"]
    assert rec["media_kind"] == "episode" and rec["movie"] is None
    ep = rec["episode"]
    assert ep["series"]["tmdb_id"] == ALPHA and (ep["season_number"], ep["episode_number"]) == (
        1,
        1,
    )
    assert ep["name"] == "S1E1" and ep["runtime_minutes"] == 45
    assert rec["engine_version"] == "weighted_v2"
    assert (
        scalar(
            engine,
            "SELECT media_kind || ':' || series_id || ':' || season_number || ':' "
            "|| episode_number FROM cineme.recommendations",
        )
        == f"episode:{ALPHA}:1:1"
    )
    # Reload never re-picks; the same single episode comes back.
    assert a.today()["recommendation"]["id"] == rec["id"]


def test_accepting_records_intent_only_and_marking_watched_advances(
    a: Shows, shows: FakeMovieProvider, engine: Engine
) -> None:
    a.add_series(ALPHA)
    a.set_media("shows")
    rec = a.choose(ctx()).json()["recommendation"]
    assert a.accept(rec["id"]).status_code == 200
    assert a.entry(ALPHA)["progress"] is None, "Watch Tonight never advances progress"
    assert scalar(engine, "SELECT count(*) FROM cineme.episode_viewings") == 0

    done = a.post(
        f"/api/v1/recommendations/{rec['id']}/watched",
        {"expected_session_version": a.version, "rating": 4},
    )
    assert done.status_code == 200
    viewing = done.json()["viewing"]
    assert viewing["movie"] is None and viewing["episode"]["episode_number"] == 1
    assert viewing["rating"] == 4
    entry = a.entry(ALPHA)
    assert entry["progress"]["episode"] == 1 and next_ep(entry) == (1, 2)
    env = a.today()
    assert env["state"] == "completed" and env["viewing"]["episode"]["season_number"] == 1
    assert scalar(engine, "SELECT count(*) FROM cineme.viewings") == 0, "movie history untouched"


def test_a_stale_episode_pick_is_refused_after_progress_moves(
    a: Shows, shows: FakeMovieProvider, engine: Engine
) -> None:
    a.add_series(ALPHA)
    a.set_media("shows")
    rec = a.choose(ctx()).json()["recommendation"]
    v = a.entry(ALPHA)["progress_version"]
    assert a.set_progress(ALPHA, v, (1, 2)).status_code == 200  # another device
    env = a.today()
    assert env["recommendation"] is None, "the pick for that show was superseded"
    stale = a.post(
        f"/api/v1/recommendations/{rec['id']}/watched",
        {"expected_session_version": env["session"]["version"]},
    )
    assert stale.status_code == 409
    assert scalar(engine, "SELECT count(*) FROM cineme.episode_viewings") == 0


def test_movies_and_shows_returns_one_recommendation_from_both(
    a: Shows, shows: FakeMovieProvider
) -> None:
    shows.series[ALPHA] = tv(ALPHA, "Alpha", genre_ids=(28,))
    a.add(104)  # Run Lola Run: genres 28/18
    shows.films[800] = film(800, "Slow Drama", genre_ids=(99,))
    a.add(800)
    a.add_series(ALPHA)
    a.set_media("movies_and_shows")
    env = a.choose(ctx(desired_experience="exciting")).json()
    assert env["state"] == "offered"
    assert env["recommendation"]["media_kind"] in ("movie", "episode")
    assert env["media"] == "movies_and_shows"
    comparison = a.client.get(
        f"/api/v1/recommendations/{env['recommendation']['id']}/comparison", headers=a.headers
    ).json()
    kinds = {"episode" if "episode" in c else "movie" for c in comparison["top_candidates"]} | {
        "episode" if "episode" in comparison["winner"] else "movie"
    }
    assert kinds == {"movie", "episode"}, "both media were ranked together"


def test_shows_only_with_nothing_eligible_explains_and_never_falls_back_to_a_movie(
    a: Shows, shows: FakeMovieProvider
) -> None:
    a.add(104)
    a.add_series(ALPHA)
    v = a.entry(ALPHA)["progress_version"]
    a.set_progress(ALPHA, v, (2, 2))  # caught up
    a.set_media("shows")
    env = a.choose(ctx()).json()
    assert env["state"] == "no_match"
    summary = env["recommendation"]["no_match_summary"]
    assert summary["primary_exclusion_counts"] == {"series_caught_up": 1}
    assert summary["hidden_by_preference"] == 1, "the movie is hidden, not offered"
    assert {"add_shows", "change_media_preference"} <= set(summary["suggested_actions"])
    assert (
        "titles" in env["recommendation"]["explanation"]
        or "title" in env["recommendation"]["explanation"]
    )


def test_shows_only_with_no_shows_is_an_empty_state_with_a_reason(
    a: Shows, shows: FakeMovieProvider
) -> None:
    a.add(104)
    a.set_media("shows")
    env = a.today()
    assert env["state"] == "empty_watchlist" and env["empty_reason"] == "no_shows"


def test_changing_the_preference_never_touches_history_watchlist_or_progress(
    a: Shows, shows: FakeMovieProvider, engine: Engine
) -> None:
    a.add(104)
    a.add_series(ALPHA)
    a.mark(ALPHA, 1, 1)
    snapshot = lambda: (  # noqa: E731
        scalar(engine, "SELECT count(*) FROM cineme.watchlist_entries WHERE status='active'"),
        scalar(engine, "SELECT count(*) FROM cineme.series_entries WHERE status='active'"),
        scalar(engine, "SELECT count(*) FROM cineme.viewings"),
        scalar(engine, "SELECT count(*) FROM cineme.episode_viewings"),
        scalar(engine, "SELECT progress_season*100+progress_episode FROM cineme.series_entries"),
    )
    before = snapshot()
    for media in ("shows", "movies_and_shows", "movies", "shows"):
        assert a.set_media(media).status_code == 200
    assert snapshot() == before


def test_changing_the_preference_supersedes_the_open_pick_without_a_replacement(
    a: Shows, shows: FakeMovieProvider
) -> None:
    a.add(104)
    a.add_series(ALPHA)
    first = a.choose(ctx()).json()["recommendation"]
    assert first["media_kind"] == "movie"
    changed = a.set_media("shows")
    assert changed.status_code == 200
    assert changed.json()["today"]["recommendation"] is None
    assert changed.json()["today"]["state"] == "ready"


def test_older_clients_never_see_an_episode_pick(a: Shows, shows: FakeMovieProvider) -> None:
    a.add_series(ALPHA)
    a.set_media("shows")
    a.choose(ctx())
    legacy = a.today(headers=a.legacy())
    assert legacy["recommendation"] is None
    assert legacy["state"] in ("empty_watchlist", "ready", "not_started")
    assert a.today()["recommendation"]["media_kind"] == "episode"


def test_rejecting_an_episode_is_temporary_and_never_recommend_blocks_the_show(
    a: Shows, shows: FakeMovieProvider, engine: Engine
) -> None:
    a.add_series(ALPHA)
    a.add_series(BETA)
    a.set_media("shows")
    first = a.choose(ctx()).json()["recommendation"]
    sid = first["episode"]["series"]["tmdb_id"]
    r = a.reject(first["id"], "not_tonight", choose_another=True)
    assert r.status_code == 200
    second = r.json()["today"]["recommendation"]
    assert second["episode"]["series"]["tmdb_id"] != sid, "the skipped show is out for tonight"
    assert a.entry(sid)["progress"] is None, "a skip never moves progress"
    assert scalar(engine, "SELECT count(*) FROM cineme.series_blocks") == 0

    never = a.reject(second["id"], "never_recommend")
    assert never.status_code == 200
    assert scalar(engine, "SELECT count(*) FROM cineme.series_blocks") == 1
    assert a.entry(second["episode"]["series"]["tmdb_id"])["progress"] is None
    assert len(a.listing(media="shows")["items"]) == 2, "the watchlist keeps both shows"

    third = a.choose(ctx(), continue_after_pause=True)
    assert third.json()["state"] in ("no_match", "offered")


def test_an_episode_cannot_be_rejected_as_already_watched(
    a: Shows, shows: FakeMovieProvider
) -> None:
    a.add_series(ALPHA)
    a.set_media("shows")
    rec = a.choose(ctx()).json()["recommendation"]
    r = a.reject(rec["id"], "already_watched")
    assert r.status_code == 422 and "progress" in r.json()["error"]["message"]
    assert a.today()["recommendation"]["id"] == rec["id"], "nothing changed"


def test_removing_the_recommended_show_clears_its_pick(a: Shows, shows: FakeMovieProvider) -> None:
    entry_id = a.add_series(ALPHA).json()["entry"]["id"]
    a.set_media("shows")
    a.choose(ctx())
    gone = a.client.delete(f"/api/v1/watchlist/{entry_id}", headers=a.headers | a.key())
    assert gone.status_code == 200
    assert gone.json()["today"]["recommendation"] is None


def test_follow_up_yes_confirms_the_episode_the_next_day(
    a: Shows, shows: FakeMovieProvider, engine: Engine
) -> None:
    a.add_series(ALPHA)
    a.set_media("shows")
    rec = a.choose(ctx()).json()["recommendation"]
    a.accept(rec["id"])
    with engine.begin() as conn:  # the accepted night was yesterday
        conn.execute(text("UPDATE cineme.recommendation_sessions SET local_date = local_date - 1"))
    env = a.today()
    assert env["follow_up"]["media_kind"] == "episode"
    assert env["follow_up"]["episode"]["episode_number"] == 1
    legacy = a.today(headers=a.legacy())
    assert legacy["follow_up"] is None, "older clients are never asked about an episode"
    done = a.post(f"/api/v1/recommendations/{rec['id']}/follow-up", {"action": "yes"})
    assert done.status_code == 200
    assert a.entry(ALPHA)["progress"]["episode"] == 1
    assert scalar(engine, "SELECT source FROM cineme.episode_viewings") == "follow_up"


# --- continuity through the whole stack ----------------------------------------


def _watched_days_ago(
    engine: Engine, user: uuid.UUID, series_id: int, days: int, genres: list[int] | None = None
) -> None:
    at = datetime.now(UTC) - timedelta(days=days)
    with engine.begin() as conn:
        conn.execute(
            text(
                "INSERT INTO cineme.episode_viewings (id, user_id, series_id, season_number, "
                "episode_number, watched_at, recorded_at, source, genre_ids_snapshot) "
                "VALUES (:id, :u, :s, 1, 1, :at, :at, 'manual', CAST(:g AS integer[]))"
            ),
            {
                "id": uuid.uuid4(),
                "u": user,
                "s": series_id,
                "at": at,
                "g": [18] if genres is None else genres,
            },
        )
        conn.execute(
            text(
                "UPDATE cineme.series_entries SET progress_season = 1, progress_episode = 1 "
                "WHERE user_id = :u AND series_id = :s"
            ),
            {"u": user, "s": series_id},
        )


def _prepared(a: Shows) -> None:
    a.add_series(BETA)  # added first: the plain tie-break would pick it
    a.add_series(ALPHA)
    a.set_media("shows")


def test_a_recently_watched_series_is_continued(
    a: Shows, shows: FakeMovieProvider, engine: Engine
) -> None:
    _prepared(a)
    _watched_days_ago(engine, a.id, ALPHA, 1)
    env = a.choose(ctx(desired_experience="surprise")).json()
    ep = env["recommendation"]["episode"]
    assert ep["series"]["tmdb_id"] == ALPHA and ep["episode_number"] == 2
    assert ep["continues_series"] is True
    reasons = env["recommendation"]["reasons"]
    assert reasons[0]["code"] == "continues_series"
    assert reasons[0]["text"] == "Continue the series you're watching — S1 E2."
    detail = a.client.get(
        f"/api/v1/recommendations/{env['recommendation']['id']}", headers=a.headers
    ).json()
    assert (
        detail["breakdown"]["contributions"]["S"] > 0 and detail["breakdown"]["weights"]["S"] == 12
    )


def test_an_idle_series_is_not_favoured(a: Shows, shows: FakeMovieProvider, engine: Engine) -> None:
    _prepared(a)
    # No genre snapshot, so the variety signal (D) is neutral for both shows and
    # only the continuity bonus could separate them.
    _watched_days_ago(engine, a.id, ALPHA, 30, [])
    env = a.choose(ctx(desired_experience="surprise")).json()
    ep = env["recommendation"]["episode"]
    assert ep["series"]["tmdb_id"] == BETA, "the bonus faded; the plain order decides"
    assert ep["continues_series"] is False


def test_showing_or_accepting_a_pick_never_creates_continuity(
    a: Shows, shows: FakeMovieProvider, engine: Engine
) -> None:
    _prepared(a)
    rec = a.choose(ctx(desired_experience="surprise")).json()["recommendation"]
    sid = rec["episode"]["series"]["tmdb_id"]
    a.accept(rec["id"])
    assert scalar(engine, "SELECT count(*) FROM cineme.episode_viewings") == 0
    assert sid in (ALPHA, BETA)
    # Nothing was confirmed, so a later night has no continuity for either show.
    with engine.begin() as conn:
        conn.execute(text("UPDATE cineme.recommendation_sessions SET local_date = local_date - 1"))
    env = a.choose(ctx(desired_experience="surprise"), expected_session_version=0).json()
    assert env["state"] == "offered"
    assert env["recommendation"]["episode"]["continues_series"] is False


def test_a_skipped_continuation_hands_the_night_to_another_title(
    a: Shows, shows: FakeMovieProvider, engine: Engine
) -> None:
    _prepared(a)
    _watched_days_ago(engine, a.id, ALPHA, 1)
    first = a.choose(ctx(desired_experience="surprise")).json()["recommendation"]
    assert first["episode"]["series"]["tmdb_id"] == ALPHA
    second = a.reject(first["id"], "not_tonight", choose_another=True).json()["today"]
    assert second["recommendation"]["episode"]["series"]["tmdb_id"] == BETA


def test_eligibility_comes_before_continuity(
    a: Shows, shows: FakeMovieProvider, engine: Engine
) -> None:
    _prepared(a)
    _watched_days_ago(engine, a.id, ALPHA, 0)
    # A runtime cap the boosted show's episode cannot meet.
    shows.episodes[ALPHA] = episodes_for(((1, 3),), runtime=90)
    with engine.begin() as conn:
        conn.execute(
            text(
                "UPDATE cineme.series SET fetched_at = fetched_at - interval '2 days', "
                "episodes_fetched_at = episodes_fetched_at - interval '2 days'"
            )
        )
    a.details(ALPHA)  # refresh the cache with the 90-minute episodes
    env = a.choose(ctx(desired_experience="surprise", max_runtime_minutes=60)).json()
    assert env["recommendation"]["episode"]["series"]["tmdb_id"] == BETA


# --- episode history ------------------------------------------------------------------------------


def test_episode_history_is_separate_paged_and_private(
    a: Shows, b: Shows, shows: FakeMovieProvider
) -> None:
    a.add_series(ALPHA)
    for episode in (1, 2, 3):
        assert a.mark(ALPHA, 1, episode, rating=episode).status_code == 200
    full = a.client.get("/api/v1/episode-viewings", headers=a.headers).json()
    assert [i["episode_number"] for i in full["items"]] == [3, 2, 1], "newest first"
    assert full["items"][0]["series"]["name"] == "Alpha" and full["items"][0]["rating"] == 3
    seen: list[int] = []
    cursor = None
    for _ in range(5):
        params: dict[str, Any] = {"limit": 2} | ({"cursor": cursor} if cursor else {})
        page = a.client.get("/api/v1/episode-viewings", params=params, headers=a.headers).json()
        seen += [i["episode_number"] for i in page["items"]]
        cursor = page["next_cursor"]
        if cursor is None:
            break
    assert seen == [3, 2, 1]
    assert b.client.get("/api/v1/episode-viewings", headers=b.headers).json()["items"] == []
    assert a.client.get("/api/v1/viewings", headers=a.headers).json()["items"] == [], (
        "film history is untouched"
    )
    bad = a.client.get("/api/v1/episode-viewings?cursor=nope", headers=a.headers)
    assert bad.status_code == 422


def test_recommendation_history_hides_episode_picks_from_older_clients(
    a: Shows, shows: FakeMovieProvider
) -> None:
    a.add_series(ALPHA)
    a.set_media("shows")
    a.choose(ctx())
    capable = a.client.get("/api/v1/recommendations", headers=a.headers).json()["items"]
    assert capable[0]["media_kind"] == "episode" and capable[0]["episode"]["episode_number"] == 1
    legacy = a.client.get("/api/v1/recommendations", headers=a.legacy()).json()["items"]
    assert legacy == []


# --- a returning show can stop being "caught up" ---


def test_choosing_refreshes_a_stale_caught_up_show_and_finds_the_new_episode(
    a: Shows, shows: FakeMovieProvider, engine: Engine
) -> None:
    a.add_series(BETA)
    v = a.entry(BETA)["progress_version"]
    assert a.set_progress(BETA, v, (1, 3)).status_code == 200
    assert state(a.entry(BETA)) == "caught_up"
    a.set_media("shows")
    # TMDB gains an episode; the cache is a few days old (no background jobs).
    shows.series[BETA] = tv(BETA, "Beta", genre_ids=(18,), seasons=((1, 4),))
    shows.episodes[BETA] = episodes_for(((1, 4),))
    with engine.begin() as conn:
        conn.execute(
            text(
                "UPDATE cineme.series SET fetched_at = fetched_at - interval '3 days', "
                "episodes_fetched_at = episodes_fetched_at - interval '3 days'"
            )
        )
    calls_before = len(shows.tv_detail_calls)
    env = a.choose(ctx()).json()
    assert env["state"] == "offered"
    ep = env["recommendation"]["episode"]
    assert (ep["series"]["tmdb_id"], ep["season_number"], ep["episode_number"]) == (BETA, 1, 4)
    assert len(shows.tv_detail_calls) == calls_before + 1, "refreshed once, before the pick"


def test_a_failed_refresh_uses_the_stale_cache_instead_of_failing_the_pick(
    a: Shows, shows: FakeMovieProvider, engine: Engine
) -> None:
    a.add_series(ALPHA)
    a.set_media("shows")
    with engine.begin() as conn:
        conn.execute(
            text(
                "UPDATE cineme.series SET fetched_at = fetched_at - interval '3 days', "
                "episodes_fetched_at = episodes_fetched_at - interval '3 days'"
            )
        )
    shows.down = True
    env = a.choose(ctx()).json()
    assert env["state"] == "offered" and env["recommendation"]["media_kind"] == "episode"


def test_movie_only_clients_never_trigger_show_refreshes(
    a: Shows, shows: FakeMovieProvider, engine: Engine
) -> None:
    a.add_series(ALPHA)
    a.add(104)
    with engine.begin() as conn:
        conn.execute(text("UPDATE cineme.series SET episodes_fetched_at = NULL"))
    calls = len(shows.tv_detail_calls)
    r = a.client.post(
        "/api/v1/today/choose",
        json={"expected_session_version": 0, "context": ctx()},
        headers=a.legacy() | a.key(),
    )
    assert r.status_code == 201
    assert len(shows.tv_detail_calls) == calls
