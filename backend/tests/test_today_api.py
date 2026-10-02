"""Today sessions, selection and recommendation commands on real PostgreSQL
(API_CONTRACT "Today and context", "Recommendation actions and history")."""

import threading
import time
import uuid
from datetime import UTC, date, datetime, timedelta
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlalchemy.engine import Engine

from app.recommendations import service as today_service
from tests.conftest import FakeMovieProvider, Signer, film
from tests.test_watchlist_api import Api, scalar

pytestmark = pytest.mark.integration

LOLA, ARRIVAL, PRIMER = 104, 329865, 14337


def ctx(**kw: Any) -> dict[str, Any]:
    return {"desired_experience": "exciting"} | kw


class Tonight(Api):
    """A signed-in user driving Today; remembers the last session version."""

    version = 0

    def _keep(self, response: Any) -> Any:
        body = response.json()
        env = body.get("today", body)
        if response.status_code < 300 and isinstance(env, dict) and env.get("session"):
            self.version = env["session"]["version"]
        return response

    def get(self) -> dict[str, Any]:
        r = self.client.get("/api/v1/today", headers=self.headers)
        assert r.status_code == 200
        return self._keep(r).json()

    def post(self, path: str, body: dict[str, Any], key: str | None = None) -> Any:
        headers = self.headers | {"Idempotency-Key": key or str(uuid.uuid4())}
        return self._keep(self.client.post(path, json=body, headers=headers))

    def choose(self, context: dict[str, Any] | None = None, **kw: Any) -> Any:
        key = kw.pop("key", None)
        body: dict[str, Any] = {"expected_session_version": self.version} | kw
        if context is not None:
            body["context"] = context
        return self.post("/api/v1/today/choose", body, key)

    def patch_context(self, context: dict[str, Any]) -> Any:
        headers = self.headers | {"Idempotency-Key": str(uuid.uuid4())}
        body = {"expected_session_version": self.version, "context": context}
        return self._keep(self.client.patch("/api/v1/today/context", json=body, headers=headers))

    def accept(self, rec_id: str) -> Any:
        return self.post(
            f"/api/v1/recommendations/{rec_id}/accept",
            {"expected_session_version": self.version},
        )

    def reject(self, rec_id: str, reason: str = "not_tonight", **kw: Any) -> Any:
        body = {"expected_session_version": self.version, "reason": reason} | kw
        return self.post(f"/api/v1/recommendations/{rec_id}/reject", body)

    def pick(self, envelope: dict[str, Any]) -> tuple[str, int]:
        rec = envelope["recommendation"]
        return rec["id"], rec["movie"]["tmdb_id"]


@pytest.fixture
def a(client: TestClient, signer: Signer) -> Tonight:
    return Tonight(client, signer)


@pytest.fixture
def b(client: TestClient, signer: Signer) -> Tonight:
    return Tonight(client, signer)


@pytest.fixture
def stocked(a: Tonight, movies: FakeMovieProvider) -> Tonight:
    """Six released, runtime-known films in A's watchlist."""
    for i in range(1, 4):
        movies.films[500 + i] = film(500 + i, f"Extra {i}", runtime_minutes=90 + i)
    for tmdb_id in (LOLA, ARRIVAL, PRIMER, 501, 502, 503):
        assert a.add(tmdb_id).status_code == 201
    return a


def recommendation_rows(engine: Engine) -> int:
    return scalar(engine, "SELECT count(*) FROM cineme.recommendations")


# --- reads and first pick ---------------------------------------------------------------


def test_get_today_never_creates_or_picks(a: Tonight, engine: Engine) -> None:
    assert a.get()["state"] == "empty_watchlist"
    a.add(LOLA)
    env = a.get()
    assert env["state"] == "not_started"
    assert env["session"] is None and env["recommendation"] is None
    assert scalar(engine, "SELECT count(*) FROM cineme.recommendation_sessions") == 0


def test_initial_choose_requires_a_desired_experience(stocked: Tonight) -> None:
    r = stocked.choose()
    assert r.status_code == 422 and r.json()["error"]["code"] == "CONTEXT_REQUIRED"
    r = stocked.choose({"current_mood": "down"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "VALIDATION_ERROR"


def test_first_pick_is_one_watchlist_film_and_reload_keeps_it(
    stocked: Tonight, engine: Engine
) -> None:
    r = stocked.choose(ctx(max_runtime_minutes=100))
    assert r.status_code == 201
    env = r.json()
    assert env["state"] == "offered"
    assert set(env) == {"state", "local_date", "session", "recommendation"}
    rec = env["recommendation"]
    assert rec["movie"]["tmdb_id"] in {LOLA, PRIMER, 501, 502, 503}
    assert rec["movie"]["runtime_minutes"] <= 100
    assert rec["engine_version"] == "weighted_v1"
    assert rec["reasons"][0]["code"] == "fits_runtime"
    assert all(r["text"] for r in rec["reasons"])
    assert "top_candidates" not in rec
    assert env["session"]["attempt_count"] == 1

    for _ in range(3):
        again = stocked.get()
        assert again["recommendation"]["id"] == rec["id"]
    second = stocked.choose(ctx(max_runtime_minutes=100))
    assert second.status_code == 200
    assert second.json()["recommendation"]["id"] == rec["id"]
    assert recommendation_rows(engine) == 1


def test_mood_only_choose_keeps_the_pick(stocked: Tonight) -> None:
    first = stocked.choose(ctx()).json()
    same = stocked.choose(ctx(current_mood="tired"))
    assert same.status_code == 200
    assert same.json()["recommendation"]["id"] == first["recommendation"]["id"]
    assert same.json()["session"]["version"] == first["session"]["version"] + 1


def test_parallel_chooses_produce_one_current_pick(stocked: Tonight, engine: Engine) -> None:
    results: list[Any] = []

    def go() -> None:
        results.append(
            stocked.client.post(
                "/api/v1/today/choose",
                json={"expected_session_version": 0, "context": ctx()},
                headers=stocked.headers | {"Idempotency-Key": str(uuid.uuid4())},
            )
        )

    threads = [threading.Thread(target=go) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    ok = [r for r in results if r.status_code in (200, 201)]
    assert len({r.json()["recommendation"]["id"] for r in ok}) == 1
    assert all(r.status_code in (200, 201, 409) for r in results)
    assert recommendation_rows(engine) == 1
    assert (
        scalar(
            engine,
            "SELECT count(*) FROM cineme.recommendations WHERE status IN ('offered','accepted')",
        )
        == 1
    )


def test_choose_replay_and_conflict(stocked: Tonight, engine: Engine) -> None:
    key = str(uuid.uuid4())
    first = stocked.choose(ctx(), key=key)
    stocked.version = 0
    replay = stocked.choose(ctx(), key=key)
    assert replay.status_code == 201 and replay.json() == first.json()
    assert recommendation_rows(engine) == 1
    conflict = stocked.choose(ctx(desired_experience="relax"), key=key)
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "IDEMPOTENCY_CONFLICT"


def test_stale_version_is_rejected(stocked: Tonight) -> None:
    stocked.choose(ctx())
    stocked.version = 0
    r = stocked.choose(ctx(desired_experience="relax"))
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "VERSION_CONFLICT"
    assert r.json()["error"]["details"] == {"current_version": 1}


# --- hard filters and no-match -------------------------------------------------------------


def test_upcoming_undated_and_unknown_runtime_respect_hard_rules(
    a: Tonight, movies: FakeMovieProvider
) -> None:
    movies.films[777] = film(777, "No Runtime", runtime_minutes=None)
    for tmdb_id in (888, 889, 777):
        a.add(tmdb_id)
    env = a.choose(ctx(max_runtime_minutes=120)).json()
    assert env["state"] == "no_match" and env["recommendation"]["movie"] is None
    summary = env["recommendation"]["no_match_summary"]
    assert summary["candidate_count"] == 3
    assert summary["primary_exclusion_counts"] == {"movie_unavailable": 2, "runtime_unknown": 1}
    assert summary["suggested_actions"] == ["edit_runtime", "add_movies"]
    assert "None of the 3 films" in env["recommendation"]["explanation"]


def test_no_cap_allows_unknown_runtime_but_never_unreleased(
    a: Tonight, movies: FakeMovieProvider
) -> None:
    movies.films[777] = film(777, "No Runtime", runtime_minutes=None)
    for tmdb_id in (888, 889, 777):
        a.add(tmdb_id)
    env = a.choose(ctx()).json()
    assert a.pick(env)[1] == 777


def test_runtime_cap_is_never_relaxed(stocked: Tonight) -> None:
    env = stocked.choose(ctx(max_runtime_minutes=60)).json()
    assert env["state"] == "no_match"
    assert env["recommendation"]["no_match_summary"]["primary_exclusion_counts"] == {
        "runtime_exceeded": 6
    }


def test_avoided_genres_exclude(stocked: Tonight) -> None:
    env = stocked.choose(ctx(avoid_genre_ids=[18])).json()
    assert env["state"] == "no_match"
    counts = env["recommendation"]["no_match_summary"]["primary_exclusion_counts"]
    assert counts == {"genre_blocked": 6}


# --- rejection, replacement and pause -------------------------------------------------------


def test_reject_is_temporary_and_selects_exactly_one_new_film(
    stocked: Tonight, engine: Engine
) -> None:
    first_id, first_movie = stocked.pick(stocked.choose(ctx()).json())
    prefs_before = scalar(engine, "SELECT genre_preferences::text FROM cineme.user_preferences")
    r = stocked.reject(first_id, "not_tonight", choose_another=True)
    assert r.status_code == 200
    body = r.json()
    assert body["replacement_outcome"] == "selected" and body["viewing"] is None
    assert body["feedback"]["reason"] == "not_tonight"
    _, second_movie = stocked.pick(body["today"])
    assert second_movie != first_movie
    assert body["today"]["session"]["rejection_count"] == 1
    assert scalar(engine, "SELECT genre_preferences::text FROM cineme.user_preferences") == (
        prefs_before
    )
    assert (
        scalar(engine, "SELECT count(*) FROM cineme.watchlist_entries WHERE status='active'") == 6
    )


def test_offered_films_never_return_the_same_day(stocked: Tonight) -> None:
    seen = []
    rec_id, movie = stocked.pick(stocked.choose(ctx()).json())
    seen.append(movie)
    for _ in range(2):
        body = stocked.reject(rec_id, choose_another=True).json()
        if body["replacement_outcome"] != "selected":
            break
        rec_id, movie = stocked.pick(body["today"])
        assert movie not in seen
        seen.append(movie)


def test_reject_without_choose_another_selects_nothing(stocked: Tonight) -> None:
    rec_id, _ = stocked.pick(stocked.choose(ctx()).json())
    body = stocked.reject(rec_id, choose_another=False).json()
    assert body["replacement_outcome"] == "not_requested"
    assert body["today"]["state"] == "ready" and body["today"]["recommendation"] is None


def test_too_long_applies_a_shorter_cap_only_when_valid(stocked: Tonight, engine: Engine) -> None:
    rec_id, _ = stocked.pick(stocked.choose(ctx(max_runtime_minutes=120)).json())
    bad = stocked.reject(rec_id, "too_long", details={"max_runtime_minutes": 120})
    assert bad.status_code == 422
    assert scalar(engine, "SELECT count(*) FROM cineme.rejection_feedback") == 0
    unknown = stocked.reject(rec_id, "too_long", details={"genre": 1})
    assert unknown.status_code == 422
    good = stocked.reject(
        rec_id, "too_long", details={"max_runtime_minutes": 85}, choose_another=True
    ).json()
    assert good["today"]["session"]["context"]["max_runtime_minutes"] == 85
    assert good["replacement_outcome"] == "selected"
    assert good["today"]["recommendation"]["movie"]["runtime_minutes"] <= 85


def test_wrong_genre_needs_the_films_own_genres(stocked: Tonight) -> None:
    rec_id, _ = stocked.pick(stocked.choose(ctx()).json())
    bad = stocked.reject(rec_id, "wrong_genre", details={"avoid_genre_ids": [99]})
    assert bad.status_code == 422
    good = stocked.reject(rec_id, "wrong_genre", details={"avoid_genre_ids": [18]}).json()
    assert good["today"]["session"]["context"]["avoid_genre_ids"] == [18]


def test_want_lighter_sets_relax_and_heaviness(stocked: Tonight) -> None:
    rec_id, _ = stocked.pick(stocked.choose(ctx(current_mood="down")).json())
    body = stocked.reject(rec_id, "want_lighter", choose_another=True).json()
    context = body["today"]["session"]["context"]
    assert context["desired_experience"] == "relax" and context["heaviness_max"] == 0.35
    assert context["current_mood"] == "down"
    uncertain = body["today"]["recommendation"]["uncertainties"]
    assert {u["values"]["trait"] for u in uncertain} == {"heaviness"}


def test_third_rejection_pauses_and_continue_once_gives_one(stocked: Tonight) -> None:
    rec_id, _ = stocked.pick(stocked.choose(ctx()).json())
    for n in (1, 2):
        body = stocked.reject(rec_id, choose_another=True).json()
        assert body["replacement_outcome"] == "selected", n
        rec_id, _ = stocked.pick(body["today"])
    paused = stocked.reject(rec_id, choose_another=True).json()
    assert paused["replacement_outcome"] == "paused"
    assert paused["today"]["state"] == "paused"
    assert paused["today"]["recommendation"] is None

    blocked = stocked.choose()
    assert blocked.status_code == 409
    assert blocked.json()["error"]["code"] == "CONTEXT_REVIEW_REQUIRED"
    mood_only = stocked.choose(ctx(current_mood="upbeat"))
    assert mood_only.status_code == 409, "an emotion-only edit is not a context review"

    once = stocked.choose(continue_after_pause=True)
    assert once.status_code == 201
    env = once.json()
    assert env["state"] == "offered" and env["session"]["rejection_count"] == 3
    again = stocked.reject(env["recommendation"]["id"], choose_another=True).json()
    assert again["replacement_outcome"] == "paused", "later rejections stay paused"


def test_a_real_context_change_lifts_the_pause(stocked: Tonight) -> None:
    rec_id, _ = stocked.pick(stocked.choose(ctx()).json())
    for _ in range(3):
        body = stocked.reject(rec_id, choose_another=True).json()
        if body["replacement_outcome"] == "selected":
            rec_id, _ = stocked.pick(body["today"])
    assert stocked.get()["state"] == "paused"
    changed = stocked.choose(ctx(desired_experience="make_me_laugh"))
    assert changed.status_code == 201
    assert changed.json()["session"]["rejection_count"] == 3


def test_daily_attempt_limit(stocked: Tonight, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(today_service, "DAILY_ATTEMPT_LIMIT", 2)
    rec_id, _ = stocked.pick(stocked.choose(ctx()).json())
    body = stocked.reject(rec_id, choose_another=True).json()
    assert body["replacement_outcome"] == "selected"
    capped = stocked.reject(body["today"]["recommendation"]["id"], choose_another=True).json()
    assert capped["replacement_outcome"] == "daily_limit"
    r = stocked.choose(ctx(desired_experience="relax"))
    assert r.status_code == 429 and r.json()["error"]["code"] == "DAILY_ATTEMPT_LIMIT"


# --- context edits and accept ----------------------------------------------------------------


def test_context_patch_noop_mood_only_and_scoring_change(stocked: Tonight, engine: Engine) -> None:
    env = stocked.choose(ctx(max_runtime_minutes=120)).json()
    rec_id = env["recommendation"]["id"]
    version = env["session"]["version"]
    same = stocked.patch_context(ctx(max_runtime_minutes=120)).json()
    assert same["session"]["version"] == version and same["recommendation"]["id"] == rec_id
    mood = stocked.patch_context(ctx(max_runtime_minutes=120, current_mood="tired")).json()
    assert mood["session"]["version"] == version + 1
    assert mood["recommendation"]["id"] == rec_id
    changed = stocked.patch_context(ctx(max_runtime_minutes=90, current_mood="tired")).json()
    assert changed["state"] == "ready" and changed["recommendation"] is None
    status = scalar(engine, "SELECT status FROM cineme.recommendations WHERE id=:i", i=rec_id)
    assert status == "superseded"


def test_accept_persists_and_creates_no_history(stocked: Tonight, engine: Engine) -> None:
    rec_id, movie = stocked.pick(stocked.choose(ctx()).json())
    accepted = stocked.accept(rec_id)
    assert accepted.status_code == 200
    env = accepted.json()
    assert env["state"] == "accepted" and env["recommendation"]["status"] == "accepted"
    assert stocked.get()["state"] == "accepted"
    again = stocked.accept(rec_id)
    assert again.status_code == 200
    assert again.json()["session"]["version"] == env["session"]["version"], "semantic no-op"
    active = scalar(
        engine,
        "SELECT count(*) FROM cineme.watchlist_entries WHERE status='active' AND movie_id=:m",
        m=movie,
    )
    assert active == 1, "accepting is not watching"
    stocked.version -= 1
    assert stocked.accept(rec_id).status_code == 409


def test_accepted_pick_survives_reload_and_choose(stocked: Tonight) -> None:
    rec_id, _ = stocked.pick(stocked.choose(ctx()).json())
    stocked.accept(rec_id)
    again = stocked.choose(ctx())
    assert again.status_code == 200 and again.json()["recommendation"]["id"] == rec_id


def test_old_or_foreign_recommendations_cannot_be_acted_on(stocked: Tonight, b: Tonight) -> None:
    rec_id, _ = stocked.pick(stocked.choose(ctx()).json())
    b.version = 1
    assert b.accept(rec_id).status_code == 404
    assert b.reject(rec_id).status_code == 404
    assert b.client.get(f"/api/v1/recommendations/{rec_id}", headers=b.headers).status_code == 404
    assert (
        b.client.get(f"/api/v1/recommendations/{rec_id}/comparison", headers=b.headers).status_code
        == 404
    )
    assert b.get()["state"] == "empty_watchlist"
    assert b.client.get("/api/v1/recommendations", headers=b.headers).json()["items"] == []
    stocked.reject(rec_id, choose_another=False)
    stocked.version = stocked.get()["session"]["version"]
    assert stocked.accept(rec_id).json()["error"]["code"] == "INVALID_TRANSITION"


def test_mutations_require_auth_and_a_key(client: TestClient, stocked: Tonight) -> None:
    assert client.get("/api/v1/today").status_code == 401
    r = client.post(
        "/api/v1/today/choose",
        json={"expected_session_version": 0, "context": ctx()},
        headers=stocked.headers,
    )
    assert r.json()["error"]["code"] == "IDEMPOTENCY_KEY_REQUIRED"
    r = stocked.choose(ctx(), user_id=str(uuid.uuid4()))
    assert r.status_code == 422, "no client-supplied owner"


# --- days and timezones ----------------------------------------------------------------------


def test_local_date_follows_the_profile_timezone_and_rolls_over(
    stocked: Tonight, monkeypatch: pytest.MonkeyPatch
) -> None:
    stocked.client.patch(
        "/api/v1/me",
        json={"timezone": "Asia/Kolkata"},
        headers=stocked.headers | {"Idempotency-Key": str(uuid.uuid4())},
    )
    clock = [datetime(2026, 10, 2, 18, 20, tzinfo=UTC)]  # 23:50 in Kolkata
    monkeypatch.setattr(today_service, "utc_now", lambda: clock[0])
    env = stocked.choose(ctx()).json()
    assert env["local_date"] == "2026-10-02"
    rec_id = env["recommendation"]["id"]

    clock[0] = datetime(2026, 10, 2, 18, 40, tzinfo=UTC)  # 00:10 next day
    next_day = stocked.get()
    assert next_day["local_date"] == "2026-10-03" and next_day["state"] == "not_started"
    stocked.version = env["session"]["version"]
    expired = stocked.accept(rec_id)
    assert expired.status_code == 409 and expired.json()["error"]["code"] == "SESSION_EXPIRED"
    stocked.version = 0
    fresh = stocked.choose(ctx()).json()
    assert fresh["local_date"] == "2026-10-03" and fresh["state"] == "offered"


def test_day_end_is_next_local_midnight(stocked: Tonight, engine: Engine) -> None:
    stocked.choose(ctx())
    with engine.connect() as conn:
        local, ends = conn.execute(
            text("SELECT local_date, day_ends_at FROM cineme.recommendation_sessions")
        ).one()
    assert ends == datetime.combine(local + timedelta(days=1), datetime.min.time(), UTC)


# --- invalidation from preferences and the watchlist ----------------------------------------


def _prefs_patch(api: Tonight, version: int, **fields: Any) -> Any:
    return api.client.patch(
        "/api/v1/me/preferences",
        json={"expected_version": version} | fields,
        headers=api.headers | {"Idempotency-Key": str(uuid.uuid4())},
    )


def test_preference_edits_clear_the_pick_but_ai_toggle_does_not(stocked: Tonight) -> None:
    rec_id, _ = stocked.pick(stocked.choose(ctx()).json())
    toggle = _prefs_patch(stocked, 1, ai_context_enabled=True).json()
    assert toggle["preferences"]["version"] == 2
    assert toggle["today"]["recommendation"]["id"] == rec_id
    blocked = _prefs_patch(stocked, 2, blocked_genre_ids=[18]).json()
    assert blocked["today"]["state"] == "ready" and blocked["today"]["recommendation"] is None
    assert blocked["today"]["session"]["overridden_fields"] == ["avoid_genre_ids"]
    stale = _prefs_patch(stocked, 1, default_max_runtime_minutes=90)
    assert stale.status_code == 409 and stale.json()["error"]["code"] == "VERSION_CONFLICT"


def test_profile_cap_combines_as_minimum(stocked: Tonight) -> None:
    _prefs_patch(stocked, 1, default_max_runtime_minutes=80)
    env = stocked.choose(ctx(max_runtime_minutes=120)).json()
    assert env["session"]["effective_context"]["max_runtime_minutes"] == 80
    assert "max_runtime_minutes" in env["session"]["overridden_fields"]
    assert env["recommendation"]["movie"]["runtime_minutes"] <= 80


def test_removing_the_pick_supersedes_it_and_adding_clears_no_match(
    stocked: Tonight, movies: FakeMovieProvider
) -> None:
    env = stocked.choose(ctx()).json()
    _, movie = stocked.pick(env)
    entry = next(
        i for i in stocked.entries(limit=50).json()["items"] if i["movie"]["tmdb_id"] == movie
    )
    removed = stocked.remove(entry["id"]).json()
    assert removed["today"]["state"] == "ready" and removed["today"]["recommendation"] is None

    stocked.version = removed["today"]["session"]["version"]
    nothing = stocked.choose(ctx(max_runtime_minutes=60)).json()
    assert nothing["state"] == "no_match"
    movies.films[600] = film(600, "Short One", runtime_minutes=55)
    added = stocked.add(600).json()
    assert added["today"]["state"] == "ready", "no-match cleared when inventory grows"


def test_adding_keeps_an_offered_pick(stocked: Tonight, movies: FakeMovieProvider) -> None:
    rec_id, _ = stocked.pick(stocked.choose(ctx()).json())
    movies.films[601] = film(601, "Another")
    assert stocked.add(601).json()["today"]["recommendation"]["id"] == rec_id


# --- history, detail and bounded evidence ---------------------------------------------------


def test_history_detail_and_comparison(stocked: Tonight, engine: Engine) -> None:
    rec_id, _ = stocked.pick(stocked.choose(ctx()).json())
    stocked.reject(rec_id, "other", note="not in the mood", choose_another=True)
    items = stocked.client.get("/api/v1/recommendations", headers=stocked.headers).json()["items"]
    assert [i["status"] for i in items] == ["offered", "rejected"]
    assert items[0]["local_date"] == items[1]["local_date"]
    detail = stocked.client.get(f"/api/v1/recommendations/{rec_id}", headers=stocked.headers).json()
    assert (
        detail["feedback"]["reason"] == "other" and detail["feedback"]["note"] == "not in the mood"
    )
    breakdown = detail["breakdown"]
    assert set(breakdown["components"]) == {"G", "C", "D", "A", "R", "Q"}
    assert breakdown["weights"] == {"G": 35, "C": 30, "D": 10, "A": 10, "R": 10, "Q": 5}
    total = sum(breakdown["contributions"].values())
    assert round(total, 2) == detail["recommendation"]["total_score"]
    comparison = stocked.client.get(
        f"/api/v1/recommendations/{rec_id}/comparison", headers=stocked.headers
    ).json()
    assert comparison["exclusion_summary"]["candidate_count"] == 6
    assert len(comparison["top_candidates"]) == 5
    assert [c["rank"] for c in comparison["top_candidates"]] == [2, 3, 4, 5, 6]
    assert len(comparison["config_hash"]) == 64


def test_at_most_nine_runners_up_are_stored(a: Tonight, engine: Engine) -> None:
    seed_watchlist(engine, a.id, 15)
    a.choose(ctx())
    assert (
        scalar(engine, "SELECT jsonb_array_length(top_candidates) FROM cineme.recommendations") == 9
    )


def seed_watchlist(engine: Engine, user_id: uuid.UUID, n: int) -> None:
    """Large synthetic watchlist inserted directly (no TMDB calls)."""
    now = datetime.now(UTC)
    with engine.begin() as conn:
        conn.execute(
            text(
                "INSERT INTO cineme.movies (tmdb_id, title, release_date, runtime_minutes,"
                " genre_ids, adult, vote_average, vote_count, fetched_at)"
                " SELECT 900000 + g, 'Synthetic ' || g, DATE '2001-01-01' + g,"
                " 70 + g % 90, ARRAY[(ARRAY[28,35,18,53,10751])[1 + g % 5]], false,"
                " (g % 10)::numeric, g * 7, :now FROM generate_series(1, :n) g"
                " ON CONFLICT DO NOTHING"
            ),
            {"n": n, "now": now},
        )
        conn.execute(
            text(
                "INSERT INTO cineme.watchlist_entries (id, user_id, movie_id, status, added_at)"
                " SELECT gen_random_uuid(), :u, 900000 + g, 'active',"
                " :now - make_interval(days => g % 200) FROM generate_series(1, :n) g"
            ),
            {"u": user_id, "n": n, "now": now},
        )


def test_five_hundred_film_watchlist_picks_one_quickly(
    a: Tonight, engine: Engine, capsys: pytest.CaptureFixture[str]
) -> None:
    seed_watchlist(engine, a.id, 500)
    started = time.perf_counter()
    r = a.choose(ctx(max_runtime_minutes=120))
    elapsed = time.perf_counter() - started
    assert r.status_code == 201
    env = r.json()
    assert env["state"] == "offered" and env["recommendation"]["movie"]["tmdb_id"] >= 900001
    assert scalar(engine, "SELECT count(*) FROM cineme.recommendations") == 1
    with capsys.disabled():
        print(f"\n500-film choose round trip: {elapsed * 1000:.0f} ms")
    assert elapsed < 5


def test_deterministic_pick_for_identical_state(a: Tonight, b: Tonight, engine: Engine) -> None:
    seed_watchlist(engine, a.id, 40)
    with engine.begin() as conn:
        conn.execute(
            text(
                "INSERT INTO cineme.watchlist_entries (id, user_id, movie_id, status, added_at)"
                " SELECT gen_random_uuid(), :b, movie_id, 'active', added_at"
                " FROM cineme.watchlist_entries WHERE user_id = :a"
            ),
            {"a": a.id, "b": b.id},
        )
    pick_a = a.choose(ctx(max_runtime_minutes=120)).json()["recommendation"]
    pick_b = b.choose(ctx(max_runtime_minutes=120, current_mood="down")).json()["recommendation"]
    assert pick_a["movie"]["tmdb_id"] == pick_b["movie"]["tmdb_id"]
    assert pick_a["total_score"] == pick_b["total_score"]


def test_local_date_is_a_date(stocked: Tonight) -> None:
    assert date.fromisoformat(stocked.get()["local_date"])


# --- already watched (ADR 006) and idempotent replays ---------------------------------


def test_already_watched_records_history_not_tonight(stocked: Tonight, engine: Engine) -> None:
    rec_id, movie = stocked.pick(stocked.choose(ctx()).json())
    prefs_before = scalar(engine, "SELECT genre_preferences::text FROM cineme.user_preferences")
    body = stocked.reject(rec_id, "already_watched").json()
    viewing = body["viewing"]
    assert viewing["movie"]["tmdb_id"] == movie
    assert viewing["watched_at"] is None, "date unknown, never assumed to be tonight"
    assert viewing["rating"] is None and viewing["source"] == "already_watched"
    assert viewing["recommendation_id"] is None, "not tonight's completion"
    assert body["replacement_outcome"] == "not_requested"
    today = body["today"]
    assert today["state"] == "ready" and today["session"]["completed_at"] is None
    assert today["session"]["rejection_count"] == 1
    status = scalar(
        engine, "SELECT status FROM cineme.watchlist_entries WHERE movie_id = :m", m=movie
    )
    assert status == "removed"
    assert scalar(engine, "SELECT genre_preferences::text FROM cineme.user_preferences") == (
        prefs_before
    )
    assert scalar(engine, "SELECT count(*) FROM cineme.viewings WHERE rating IS NOT NULL") == 0
    # Re-adding a known-watched film is refused, so it can't come back.
    again = stocked.add(movie)
    assert again.status_code == 409 and again.json()["error"]["code"] == "MOVIE_ALREADY_WATCHED"


def test_watched_films_are_excluded_from_future_picks(
    stocked: Tonight, engine: Engine, monkeypatch: pytest.MonkeyPatch
) -> None:
    rec_id, movie = stocked.pick(stocked.choose(ctx()).json())
    stocked.reject(rec_id, "already_watched", choose_another=True)
    # Even if the archived entry were active again, the viewing excludes it.
    with engine.begin() as conn:
        conn.execute(
            text(
                "UPDATE cineme.watchlist_entries SET status='active', removed_at=NULL"
                " WHERE movie_id = :m"
            ),
            {"m": movie},
        )
    clock = [datetime.now(UTC) + timedelta(days=2)]
    monkeypatch.setattr(today_service, "utc_now", lambda: clock[0])
    stocked.version = 0
    seen = set()
    rec = stocked.choose(ctx()).json()
    while rec["recommendation"] and rec["recommendation"]["status"] == "offered":
        seen.add(rec["recommendation"]["movie"]["tmdb_id"])
        nxt = stocked.reject(rec["recommendation"]["id"], choose_another=True).json()
        if nxt["replacement_outcome"] != "selected":
            break
        rec = nxt["today"]
    assert movie not in seen
    counts = stocked.choose(ctx(desired_experience="relax")).json()
    if counts["state"] == "no_match":
        assert (
            "already_watched"
            in counts["recommendation"]["no_match_summary"]["primary_exclusion_counts"]
        )


def test_already_watched_accepts_a_past_date_only(stocked: Tonight) -> None:
    rec_id, _ = stocked.pick(stocked.choose(ctx()).json())
    future = (datetime.now(UTC) + timedelta(days=1)).isoformat()
    assert (
        stocked.reject(rec_id, "already_watched", details={"watched_at": future}).status_code == 422
    )
    assert stocked.reject(rec_id, "already_watched", details={"rating": "loved"}).status_code == 422
    past = "2019-05-04T20:00:00+00:00"
    body = stocked.reject(rec_id, "already_watched", details={"watched_at": past}).json()
    assert body["viewing"]["watched_at"] == "2019-05-04T20:00:00Z"


def test_reject_and_accept_replays_never_apply_twice(stocked: Tonight, engine: Engine) -> None:
    rec_id, _ = stocked.pick(stocked.choose(ctx()).json())
    version = stocked.version
    key = str(uuid.uuid4())
    body = {
        "expected_session_version": version,
        "reason": "already_watched",
        "choose_another": True,
    }
    first = stocked.post(f"/api/v1/recommendations/{rec_id}/reject", body, key)
    replay = stocked.post(f"/api/v1/recommendations/{rec_id}/reject", body, key)
    assert replay.status_code == first.status_code == 200
    assert replay.json() == first.json(), "the stored response, even though the version moved"
    assert scalar(engine, "SELECT count(*) FROM cineme.rejection_feedback") == 1
    assert scalar(engine, "SELECT count(*) FROM cineme.viewings") == 1
    assert scalar(engine, "SELECT count(*) FROM cineme.recommendations") == 2
    conflict = stocked.post(
        f"/api/v1/recommendations/{rec_id}/reject", body | {"reason": "not_tonight"}, key
    )
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "IDEMPOTENCY_CONFLICT"

    new_id = first.json()["today"]["recommendation"]["id"]
    stocked.version = first.json()["today"]["session"]["version"]
    accept_key = str(uuid.uuid4())
    a1 = stocked.post(
        f"/api/v1/recommendations/{new_id}/accept",
        {"expected_session_version": stocked.version},
        accept_key,
    )
    a2 = stocked.post(
        f"/api/v1/recommendations/{new_id}/accept",
        {"expected_session_version": a1.json()["session"]["version"] - 1},
        accept_key,
    )
    assert a2.json() == a1.json()


def test_viewings_are_private(stocked: Tonight, b: Tonight, engine: Engine) -> None:
    rec_id, movie = stocked.pick(stocked.choose(ctx()).json())
    stocked.reject(rec_id, "already_watched")
    assert b.add(movie).status_code == 201, "A's history never blocks B"
    b_pick = b.choose(ctx()).json()
    assert b_pick["recommendation"]["movie"]["tmdb_id"] == movie
    assert scalar(engine, "SELECT count(*) FROM cineme.viewings WHERE user_id = :u", u=b.id) == 0
