"""The real TMDB adapter against mocked HTTP (no network)."""

from datetime import date
from typing import Any

import httpx
import pytest

from app.core.errors import AppError
from app.movies.provider import (
    FALLBACK_IMAGE_BASE,
    TmdbProvider,
    normalize_movie,
    poster_url,
)

TOKEN = "tmdb-secret-test-token"


def provider(
    handler: Any, clock: list[float] | None = None
) -> tuple[TmdbProvider, list[httpx.Request]]:
    seen: list[httpx.Request] = []

    def wrapped(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        response: httpx.Response = handler(request)
        return response

    t = clock if clock is not None else [0.0]
    p = TmdbProvider(
        TOKEN,
        httpx.Client(transport=httpx.MockTransport(wrapped)),
        clock=lambda: t[0],
        sleep=lambda s: None,
    )
    return p, seen


def raw(**overrides: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "id": 104,
        "title": "Run Lola Run",
        "original_title": "Lola rennt",
        "release_date": "1998-08-20",
        "genre_ids": [28, 18, 53],
        "poster_path": "/abc123.jpg",
        "overview": "Lola has twenty minutes.",
        "adult": False,
        "vote_average": 7.3,
        "vote_count": 2900,
    }
    base.update(overrides)
    return base


def code(fn: Any) -> tuple[int, str]:
    with pytest.raises(AppError) as info:
        fn()
    return info.value.status, info.value.code


# --- normalization -----------------------------------------------------------


def test_search_item_keeps_facts_and_leaves_unknowns_null() -> None:
    m = normalize_movie(raw())
    assert m is not None
    assert (m.tmdb_id, m.title, m.original_title) == (104, "Run Lola Run", "Lola rennt")
    assert m.release_date == date(1998, 8, 20)
    assert m.genre_ids == (28, 18, 53)
    assert m.runtime_minutes is None, "search never carries runtime"
    assert (m.vote_average, m.vote_count) == (7.3, 2900)


@pytest.mark.parametrize(
    ("overrides", "field", "expected"),
    [
        ({"release_date": ""}, "release_date", None),
        ({"release_date": "2020-13-40"}, "release_date", None),
        ({"poster_path": None}, "poster_path", None),
        ({"poster_path": "https://evil.example/x.jpg"}, "poster_path", None),
        ({"poster_path": "/../../etc/passwd"}, "poster_path", None),
        ({"overview": "   "}, "overview", None),
        ({"vote_average": 11}, "vote_average", None),
        ({"vote_average": "7"}, "vote_average", None),
        ({"vote_count": -1}, "vote_count", None),
        ({"genre_ids": [28, 28, "x", -3, True]}, "genre_ids", (28,)),
        ({"genre_ids": None}, "genre_ids", ()),
        ({"original_title": "Run Lola Run"}, "original_title", None),
        ({"adult": "yes"}, "adult", False),
    ],
)
def test_partial_or_malformed_fields_become_unknown(
    overrides: dict[str, Any], field: str, expected: Any
) -> None:
    m = normalize_movie(raw(**overrides))
    assert m is not None
    assert getattr(m, field) == expected


@pytest.mark.parametrize(
    "item", [raw(id=None), raw(id=0), raw(id="104"), raw(title=""), raw(title=None), "x", None]
)
def test_items_without_identity_or_title_are_skipped(item: Any) -> None:
    assert normalize_movie(item) is None


@pytest.mark.parametrize(("runtime", "expected"), [(0, None), (None, None), (-5, None), (81, 81)])
def test_details_runtime_zero_is_unknown(runtime: Any, expected: int | None) -> None:
    m = normalize_movie(
        raw(runtime=runtime, genres=[{"id": 28, "name": "Action"}, {"bad": 1}]), details=True
    )
    assert m is not None
    assert m.runtime_minutes == expected
    assert m.genre_ids == (28,)


def test_poster_url_uses_only_vetted_relative_paths() -> None:
    assert poster_url(FALLBACK_IMAGE_BASE, "/abc.jpg") == "https://image.tmdb.org/t/p/w500/abc.jpg"
    assert poster_url(FALLBACK_IMAGE_BASE, None) is None
    assert poster_url(FALLBACK_IMAGE_BASE, "//evil.example/a.jpg") is None


# --- HTTP behaviour ----------------------------------------------------------


def test_search_sends_bearer_and_safe_params_and_caps_pages() -> None:
    p, seen = provider(
        lambda r: httpx.Response(
            200, json={"page": 1, "total_pages": 9999, "results": [raw(), raw(id=5, title="")]}
        )
    )
    page = p.search("lola", 1)
    assert [m.tmdb_id for m in page.results] == [104]
    assert page.total_pages == 500
    request = seen[0]
    assert request.headers["Authorization"] == f"Bearer {TOKEN}"
    assert request.url.params["include_adult"] == "false"
    assert request.url.params["query"] == "lola"


def test_rate_limit_is_429_with_bounded_retry_after() -> None:
    p, _ = provider(lambda r: httpx.Response(429, headers={"Retry-After": "3600"}))
    with pytest.raises(AppError) as info:
        p.search("lola", 1)
    assert (info.value.status, info.value.code) == (429, "RATE_LIMITED")
    assert info.value.details == {"retry_after_seconds": 60}


def test_not_found_is_404() -> None:
    p, _ = provider(lambda r: httpx.Response(404, json={"status_code": 34}))
    assert code(lambda: p.details(999)) == (404, "NOT_FOUND")


def test_bad_credential_is_503_not_a_user_error() -> None:
    p, _ = provider(lambda r: httpx.Response(401, json={"status_code": 7}))
    assert code(lambda: p.search("lola", 1)) == (503, "DEPENDENCY_UNAVAILABLE")


def test_transient_failure_is_retried_once() -> None:
    calls = iter([httpx.Response(503), httpx.Response(200, json={"results": [raw()]})])
    p, seen = provider(lambda r: next(calls))
    assert len(p.search("lola", 1).results) == 1
    assert len(seen) == 2


def test_timeout_then_timeout_is_503() -> None:
    def slow(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("slow", request=request)

    p, seen = provider(slow)
    assert code(lambda: p.search("lola", 1)) == (503, "DEPENDENCY_UNAVAILABLE")
    assert len(seen) == 2, "one retry, then give up"


def test_no_retry_once_the_budget_is_spent() -> None:
    clock = [0.0]

    def slow(request: httpx.Request) -> httpx.Response:
        clock[0] += 7.5  # first attempt eats the 8 s budget
        raise httpx.ReadTimeout("slow", request=request)

    p, seen = provider(slow, clock)
    assert code(lambda: p.search("lola", 1)) == (503, "DEPENDENCY_UNAVAILABLE")
    assert len(seen) == 1


@pytest.mark.parametrize(
    "response",
    [
        httpx.Response(200, text="<html>"),
        httpx.Response(200, json={"results": "nope"}),
        httpx.Response(200, json=[]),
    ],
)
def test_malformed_search_payload_is_502(response: httpx.Response) -> None:
    p, _ = provider(lambda r: response)
    assert code(lambda: p.search("lola", 1)) == (502, "UPSTREAM_INVALID_RESPONSE")


def test_details_for_a_different_id_is_rejected() -> None:
    p, _ = provider(lambda r: httpx.Response(200, json=raw(id=105)))
    assert code(lambda: p.details(104)) == (502, "UPSTREAM_INVALID_RESPONSE")


def test_genres_and_image_base_are_cached() -> None:
    p, seen = provider(
        lambda r: (
            httpx.Response(200, json={"genres": [{"id": 28, "name": "Action"}]})
            if "genre" in r.url.path
            else httpx.Response(
                200, json={"images": {"secure_base_url": "https://image.tmdb.org/t/p/"}}
            )
        )
    )
    assert p.genres()[0].name == "Action"
    assert p.genres()[0].name == "Action"
    assert p.image_base() == "https://image.tmdb.org/t/p/"
    p.image_base()
    assert len(seen) == 2


def test_image_base_rejects_foreign_hosts_and_survives_outage() -> None:
    p, _ = provider(
        lambda r: httpx.Response(200, json={"images": {"secure_base_url": "https://evil.example/"}})
    )
    assert p.image_base() == FALLBACK_IMAGE_BASE
    down, _ = provider(lambda r: httpx.Response(503))
    assert down.image_base() == FALLBACK_IMAGE_BASE


def test_token_never_appears_in_errors() -> None:
    p, _ = provider(lambda r: httpx.Response(500, text=TOKEN))
    with pytest.raises(AppError) as info:
        p.search("lola", 1)
    assert TOKEN not in info.value.message
    assert TOKEN not in str(info.value.details)


def test_release_gate_is_separate_from_saving() -> None:
    from app.movies.service import can_add, is_released

    today = date(2026, 10, 2)
    assert is_released(today, today)
    assert not is_released(date(2026, 10, 3), today)
    assert not is_released(None, today), "unknown never counts as released"
    assert can_add(adult=False) and not can_add(adult=True)
