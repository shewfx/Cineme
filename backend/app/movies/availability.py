"""Where a film can be watched, per region (ADR 007). JustWatch data via
TMDB, fetched by the backend only, cached on the shared movie row for 24 h.
Display-only: availability never enters ranking."""

import uuid
from datetime import UTC, datetime, timedelta
from functools import cache
from importlib import resources
from typing import Any

from sqlalchemy import update
from sqlalchemy.orm import Session

from app.core.errors import AppError
from app.users.models import User

from .models import Movie
from .provider import MovieMetadataProvider, logo_url

FRESH_FOR = timedelta(hours=24)
GROUPS = ("streaming", "free", "rent", "buy")


@cache
def _zone_countries() -> dict[str, str]:
    """IANA zone -> ISO country from tzdata's zone.tab (no network)."""
    text = resources.files("tzdata").joinpath("zoneinfo/zone.tab").read_text(encoding="utf-8")
    zones = {}
    for line in text.splitlines():
        if line and not line.startswith("#"):
            code, _, zone, *_ = line.split("\t")
            zones[zone] = code
    return zones


@cache
def iso_countries() -> frozenset[str]:
    text = resources.files("tzdata").joinpath("zoneinfo/iso3166.tab").read_text(encoding="utf-8")
    return frozenset(
        line.split("\t")[0] for line in text.splitlines() if line and not line.startswith("#")
    )


def region_for(user: User) -> str | None:
    """The user's chosen region, else the one their timezone implies, else
    unknown (UTC implies nothing)."""
    return user.country_code or _zone_countries().get(user.timezone)


def _out(offers: list[dict[str, Any]], base: str) -> list[dict[str, Any]]:
    return [
        {"id": o["id"], "name": o["name"], "logo_url": logo_url(base, o.get("logo_path"))}
        for o in offers
    ]


def availability(
    session: Session, provider: MovieMetadataProvider, user_id: uuid.UUID, tmdb_id: int
) -> dict[str, Any]:
    user = session.get(User, user_id)
    if user is None:
        raise AppError(409, "PROFILE_NOT_INITIALIZED", "Your Cinemé profile is not set up yet.")
    movie = session.get(Movie, tmdb_id)
    if movie is None:
        raise AppError(404, "NOT_FOUND", "That film was not found.")
    region = region_for(user)
    cached, fetched_at = movie.watch_providers, movie.watch_providers_fetched_at
    session.rollback()  # no transaction held during the network call
    empty: dict[str, Any] = {g: [] for g in GROUPS} | {"link": None}
    if region is None:
        return {"tmdb_id": tmdb_id, "region": None, **empty, "fetched_at": None, "stale": False}
    stale = False
    now = datetime.now(UTC)
    if cached is None or fetched_at is None or fetched_at <= now - FRESH_FOR:
        try:
            cached = provider.watch_providers(tmdb_id)
            fetched_at = now
            with session.begin():
                session.execute(
                    update(Movie)
                    .where(Movie.tmdb_id == tmdb_id)
                    .values(watch_providers=cached, watch_providers_fetched_at=now)
                )
        except AppError as e:
            if cached is None or e.status not in (429, 502, 503):
                raise
            stale = True  # an outage never hides what we last knew
    data = (cached or {}).get(region) or empty
    base = provider.image_base()
    return {
        "tmdb_id": tmdb_id,
        "region": region,
        "link": data.get("link"),
        **{g: _out(data.get(g, []), base) for g in GROUPS},
        "fetched_at": fetched_at.astimezone(UTC).isoformat() if fetched_at else None,
        "stale": stale,
    }


def regions(provider: MovieMetadataProvider) -> list[dict[str, str]]:
    return [{"code": c, "name": n} for c, n in provider.watch_regions()]
