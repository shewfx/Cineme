"""TMDB adapter (ARCHITECTURE "Provider boundaries").

Returns Cinemé-owned values, never raw TMDB payloads. Unknown stays None:
runtime 0 becomes None, an empty date is unknown, invalid poster paths are
dropped. Bounded timeouts and one retry for transient failures on reads.
"""

import logging
import re
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import date
from typing import Any, Protocol

import httpx

from app.core.errors import AppError

log = logging.getLogger("cineme.tmdb")

TMDB_API = "https://api.themoviedb.org/3"
FALLBACK_IMAGE_BASE = "https://image.tmdb.org/t/p/"
POSTER_SIZE = "w500"
MAX_PAGES = 500
TRENDING_TTL_SECONDS = 3600.0
POPULAR_CACHE_ENTRIES = 8
_POSTER_PATH = re.compile(r"^/[A-Za-z0-9_-]+\.(jpg|jpeg|png|webp)$")

# connect 3 s / read 5 s; whole operation (incl. one retry) within 8 s.
TIMEOUT = httpx.Timeout(5.0, connect=3.0)
BUDGET_SECONDS = 8.0
MAX_RETRY_AFTER_SECONDS = 60
CONNECT_RETRIES = 3


@dataclass(frozen=True)
class GenreRef:
    id: int
    name: str


@dataclass(frozen=True)
class ProviderMovie:
    """Normalized movie metadata. Details-only fields are None on search."""

    tmdb_id: int
    title: str
    original_title: str | None
    release_date: date | None
    genre_ids: tuple[int, ...]
    poster_path: str | None
    overview: str | None
    adult: bool
    vote_average: float | None
    vote_count: int | None
    runtime_minutes: int | None = None
    original_language: str | None = None
    genres: tuple[GenreRef, ...] = field(default=())


@dataclass(frozen=True)
class ProviderSearchPage:
    page: int
    total_pages: int
    results: tuple[ProviderMovie, ...]


class MovieMetadataProvider(Protocol):
    def search(self, query: str, page: int) -> ProviderSearchPage: ...

    def trending(self) -> tuple[ProviderMovie, ...]:
        """This week's globally trending films (TMDB), not personalized."""

    def popular_releases(self, start: date, end: date) -> tuple[ProviderMovie, ...]:
        """Films with a primary release date from `start` to `end` inclusive,
        by current TMDB popularity. One page; not trending history."""

    def details(self, tmdb_id: int) -> ProviderMovie:
        """Raises AppError 404 NOT_FOUND for an unknown film."""

    def genres(self) -> tuple[GenreRef, ...]: ...

    def image_base(self) -> str:
        """Secure base URL for posters, e.g. https://image.tmdb.org/t/p/."""

    def watch_providers(self, tmdb_id: int) -> dict[str, Any]:
        """Normalized availability per region (JustWatch data via TMDB):
        {region: {"link", "streaming", "free", "rent", "buy"}}."""

    def watch_regions(self) -> tuple[tuple[str, str], ...]:
        """(ISO 3166-1 code, English name) regions TMDB has providers for."""


# --- normalization -----------------------------------------------------------

_REGION = re.compile(r"^[A-Z]{2}$")
# TMDB monetization types -> Cinemé groups; subscription first in the UI.
_KINDS = {"flatrate": "streaming", "free": "free", "ads": "free", "rent": "rent", "buy": "buy"}


def _offers(raw: object) -> list[dict[str, Any]]:
    """Valid providers only, by TMDB display priority then name; no dupes."""
    if not isinstance(raw, list):
        return []
    seen: set[int] = set()
    offers = []
    for p in raw:
        if not isinstance(p, dict):
            continue
        pid, name = p.get("provider_id"), p.get("provider_name")
        if not isinstance(pid, int) or isinstance(pid, bool) or pid in seen:
            continue
        if not isinstance(name, str) or not name.strip():
            continue
        priority = p.get("display_priority")
        seen.add(pid)
        offers.append(
            {
                "id": pid,
                "name": name.strip(),
                "logo_path": _poster(p.get("logo_path")),
                "priority": priority if isinstance(priority, int) else 9999,
            }
        )
    return sorted(offers, key=lambda o: (o["priority"], o["name"]))


def normalize_watch_providers(raw: object) -> dict[str, Any]:
    if not isinstance(raw, dict) or not isinstance(raw.get("results"), dict):
        raise _upstream_invalid()
    regions: dict[str, Any] = {}
    for code, data in raw["results"].items():
        if not isinstance(code, str) or not _REGION.fullmatch(code) or not isinstance(data, dict):
            continue
        groups: dict[str, list[dict[str, Any]]] = {
            "streaming": [],
            "free": [],
            "rent": [],
            "buy": [],
        }
        for kind, group in _KINDS.items():
            ids = {o["id"] for o in groups[group]}
            groups[group] += [o for o in _offers(data.get(kind)) if o["id"] not in ids]
        link = data.get("link")
        regions[code] = {
            "link": link
            if isinstance(link, str) and link.startswith("https://www.themoviedb.org/")
            else None,
            **groups,
        }
    return regions


def _upstream_invalid() -> AppError:
    return AppError(
        502,
        "UPSTREAM_INVALID_RESPONSE",
        "The movie database sent an unexpected response.",
        retryable=True,
    )


def _opt_str(value: object) -> str | None:
    return value.strip() if isinstance(value, str) and value.strip() else None


def _date(value: object) -> date | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return date.fromisoformat(value)
    except ValueError:
        return None


def _poster(value: object) -> str | None:
    return value if isinstance(value, str) and _POSTER_PATH.fullmatch(value) else None


def _vote_average(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, int | float):
        return None
    return round(float(value), 2) if 0 <= value <= 10 else None


def _vote_count(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value if value >= 0 else None


def _runtime(value: object) -> int | None:
    # TMDB uses 0 for "unknown"; never treat it as a zero-minute film.
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value if 1 <= value <= 600 else None


def _ids(value: object) -> tuple[int, ...]:
    if not isinstance(value, list):
        return ()
    seen: dict[int, None] = {}
    for v in value:
        if isinstance(v, int) and not isinstance(v, bool) and v > 0:
            seen[v] = None
    return tuple(seen)


def normalize_movie(raw: object, *, details: bool = False) -> ProviderMovie | None:
    """None when the item lacks a usable id or title (skipped, never guessed)."""
    if not isinstance(raw, dict):
        return None
    tmdb_id = raw.get("id")
    title = _opt_str(raw.get("title"))
    if not isinstance(tmdb_id, int) or isinstance(tmdb_id, bool) or tmdb_id <= 0 or not title:
        return None
    genres: tuple[GenreRef, ...] = ()
    if details and isinstance(raw.get("genres"), list):
        genres = tuple(
            GenreRef(g["id"], g["name"])
            for g in raw["genres"]
            if isinstance(g, dict)
            and isinstance(g.get("id"), int)
            and isinstance(g.get("name"), str)
        )
    genre_ids = tuple(g.id for g in genres) if details else _ids(raw.get("genre_ids"))
    original_title = _opt_str(raw.get("original_title"))
    return ProviderMovie(
        tmdb_id=tmdb_id,
        title=title,
        original_title=original_title if original_title != title else None,
        release_date=_date(raw.get("release_date")),
        genre_ids=genre_ids,
        poster_path=_poster(raw.get("poster_path")),
        overview=_opt_str(raw.get("overview")),
        adult=raw.get("adult") is True,
        vote_average=_vote_average(raw.get("vote_average")),
        vote_count=_vote_count(raw.get("vote_count")),
        runtime_minutes=_runtime(raw.get("runtime")) if details else None,
        original_language=(_opt_str(raw.get("original_language")) or "")[:8] or None
        if details
        else None,
        genres=genres,
    )


# --- HTTP client -------------------------------------------------------------


class TmdbProvider:
    """Thread-safe enough for one worker: httpx.Client is thread-safe and the
    small caches are replaced atomically."""

    def __init__(
        self,
        token: str,
        client: httpx.Client | None = None,
        *,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        # transport retries re-attempt only connection setup (nothing has been
        # sent yet); some networks reset new TLS connections to TMDB. Pooled
        # keep-alive connections avoid new handshakes after the first success.
        self._client = client or httpx.Client(
            timeout=TIMEOUT, transport=httpx.HTTPTransport(retries=CONNECT_RETRIES)
        )
        self._headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
        self._clock = clock
        self._sleep = sleep
        self._genres: tuple[float, tuple[GenreRef, ...]] | None = None
        self._image_base: tuple[float, str] | None = None
        self._regions: tuple[float, tuple[tuple[str, str], ...]] | None = None
        self._trending: tuple[float, tuple[ProviderMovie, ...]] | None = None
        # (start, end) -> (fetched at, films); a handful of keys, oldest dropped.
        self._popular: dict[tuple[date, date], tuple[float, tuple[ProviderMovie, ...]]] = {}

    def _get(self, path: str, params: dict[str, Any]) -> Any:
        deadline = self._clock() + BUDGET_SECONDS
        for attempt in (1, 2):
            try:
                response = self._client.get(
                    f"{TMDB_API}{path}", params=params, headers=self._headers
                )
            except httpx.HTTPError as e:
                # Error class only: never URLs with queries, headers or tokens.
                log.warning("tmdb %s failed attempt=%d error=%s", path, attempt, type(e).__name__)
                if attempt == 1 and self._clock() + 1 < deadline:
                    self._sleep(0.3)
                    continue
                raise _unavailable() from e
            status = response.status_code
            if status != 200:
                log.warning("tmdb %s status=%d attempt=%d", path, status, attempt)
            if status in (502, 503, 504) and attempt == 1 and self._clock() + 1 < deadline:
                self._sleep(0.3)
                continue
            if status == 429:
                raise _rate_limited(response.headers.get("Retry-After"))
            if status == 404:
                raise AppError(404, "NOT_FOUND", "That film was not found.")
            if status in (401, 403):
                # Our credential, not the user's: an operator problem.
                raise _unavailable()
            if status != 200:
                raise _unavailable()
            try:
                return response.json()
            except ValueError as e:
                raise _upstream_invalid() from e
        raise _unavailable()  # pragma: no cover (loop always returns or raises)

    def search(self, query: str, page: int) -> ProviderSearchPage:
        data = self._get(
            "/search/movie",
            {"query": query, "page": page, "include_adult": "false", "language": "en-US"},
        )
        if not isinstance(data, dict) or not isinstance(data.get("results"), list):
            raise _upstream_invalid()
        total = data.get("total_pages")
        total_pages = min(total, MAX_PAGES) if isinstance(total, int) and total >= 0 else 0
        results = tuple(m for m in (normalize_movie(r) for r in data["results"]) if m is not None)
        return ProviderSearchPage(page=page, total_pages=total_pages, results=results)

    def trending(self) -> tuple[ProviderMovie, ...]:
        """/trending/movie/week, one page, cached in process for an hour.
        A failed refresh serves the last good copy while one exists."""
        cached = self._trending
        if cached is not None and self._clock() - cached[0] < TRENDING_TTL_SECONDS:
            return cached[1]
        try:
            data = self._get("/trending/movie/week", {"language": "en-US"})
            if not isinstance(data, dict) or not isinstance(data.get("results"), list):
                raise _upstream_invalid()
        except AppError:
            if cached is not None:
                return cached[1]
            raise
        movies = tuple(m for m in (normalize_movie(r) for r in data["results"]) if m is not None)
        self._trending = (self._clock(), movies)
        return movies

    def popular_releases(self, start: date, end: date) -> tuple[ProviderMovie, ...]:
        """/discover/movie sorted by popularity for a release-date window,
        cached an hour per window (at most a few windows, oldest dropped); a
        failed refresh serves the last good copy while one exists."""
        key = (start, end)
        cached = self._popular.get(key)
        if cached is not None and self._clock() - cached[0] < TRENDING_TTL_SECONDS:
            return cached[1]
        try:
            data = self._get(
                "/discover/movie",
                {
                    "language": "en-US",
                    "sort_by": "popularity.desc",
                    "include_adult": "false",
                    "include_video": "false",
                    "page": 1,
                    "primary_release_date.gte": start.isoformat(),
                    "primary_release_date.lte": end.isoformat(),
                },
            )
            if not isinstance(data, dict) or not isinstance(data.get("results"), list):
                raise _upstream_invalid()
        except AppError:
            if cached is not None:
                return cached[1]
            raise
        movies = tuple(m for m in (normalize_movie(r) for r in data["results"]) if m is not None)
        self._popular[key] = (self._clock(), movies)
        while len(self._popular) > POPULAR_CACHE_ENTRIES:
            del self._popular[next(iter(self._popular))]
        return movies

    def details(self, tmdb_id: int) -> ProviderMovie:
        data = self._get(f"/movie/{tmdb_id}", {"language": "en-US"})
        movie = normalize_movie(data, details=True)
        if movie is None or movie.tmdb_id != tmdb_id:
            raise _upstream_invalid()
        return movie

    def genres(self) -> tuple[GenreRef, ...]:
        """Cached 24 h in process; the registry rarely changes."""
        cached = self._genres
        if cached and self._clock() - cached[0] < 86400:
            return cached[1]
        data = self._get("/genre/movie/list", {"language": "en-US"})
        if not isinstance(data, dict) or not isinstance(data.get("genres"), list):
            raise _upstream_invalid()
        genres = tuple(
            GenreRef(g["id"], g["name"])
            for g in data["genres"]
            if isinstance(g, dict)
            and isinstance(g.get("id"), int)
            and isinstance(g.get("name"), str)
        )
        self._genres = (self._clock(), genres)
        return genres

    def watch_providers(self, tmdb_id: int) -> dict[str, Any]:
        """One call for every region; the service caches it per film."""
        return normalize_watch_providers(self._get(f"/movie/{tmdb_id}/watch/providers", {}))

    def watch_regions(self) -> tuple[tuple[str, str], ...]:
        """Cached 24 h in process."""
        cached = self._regions
        if cached and self._clock() - cached[0] < 86400:
            return cached[1]
        data = self._get("/watch/providers/regions", {"language": "en-US"})
        if not isinstance(data, dict) or not isinstance(data.get("results"), list):
            raise _upstream_invalid()
        regions = tuple(
            sorted(
                (
                    (r["iso_3166_1"], r["english_name"])
                    for r in data["results"]
                    if isinstance(r, dict)
                    and isinstance(r.get("iso_3166_1"), str)
                    and _REGION.fullmatch(r["iso_3166_1"])
                    and isinstance(r.get("english_name"), str)
                ),
                key=lambda r: r[1],
            )
        )
        self._regions = (self._clock(), regions)
        return regions

    def image_base(self) -> str:
        """TMDB configuration cached 24 h; safe fallback if unavailable."""
        cached = self._image_base
        if cached and self._clock() - cached[0] < 86400:
            return cached[1]
        base = FALLBACK_IMAGE_BASE
        try:
            data = self._get("/configuration", {})
            candidate = (
                data.get("images", {}).get("secure_base_url") if isinstance(data, dict) else None
            )
            if isinstance(candidate, str) and candidate.startswith("https://image.tmdb.org/"):
                base = candidate
        except AppError:
            pass
        self._image_base = (self._clock(), base)
        return base


def _unavailable() -> AppError:
    return AppError(
        503,
        "DEPENDENCY_UNAVAILABLE",
        "The movie database is unavailable. Try again shortly.",
        retryable=True,
    )


def _rate_limited(retry_after: str | None) -> AppError:
    seconds = 10
    if retry_after and retry_after.isdigit():
        seconds = min(int(retry_after), MAX_RETRY_AFTER_SECONDS)
    return AppError(
        429,
        "RATE_LIMITED",
        "Too many searches right now. Try again in a moment.",
        details={"retry_after_seconds": seconds},
        retryable=True,
    )


def logo_url(image_base: str, logo_path: str | None) -> str | None:
    """Provider logos use the same vetted paths, at a small size."""
    if not logo_path or not _POSTER_PATH.fullmatch(logo_path):
        return None
    return f"{image_base.rstrip('/')}/w92{logo_path}"


def poster_url(image_base: str, poster_path: str | None) -> str | None:
    """Only vetted TMDB-relative paths on the allowed HTTPS image host."""
    if not poster_path or not _POSTER_PATH.fullmatch(poster_path):
        return None
    return f"{image_base.rstrip('/')}/{POSTER_SIZE}{poster_path}"
