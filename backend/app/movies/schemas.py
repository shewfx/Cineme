"""Cinemé-owned movie shapes (API_CONTRACT "MovieSummary / MovieDetails").
Never a pass-through of TMDB payloads; unknown values are null."""

from datetime import date, datetime

from pydantic import BaseModel


class GenreOut(BaseModel):
    id: int
    name: str


class MovieSummary(BaseModel):
    tmdb_id: int
    title: str
    year: int | None
    # Null on search unless details are already cached; never fabricated.
    runtime_minutes: int | None
    # TMDB community rating, display-only; null when unknown or not cached
    # (search never fetches it). Never a recommendation signal.
    vote_average: float | None = None
    genre_ids: list[int]
    genres: list[GenreOut]
    poster_url: str | None
    # False only for adult or unavailable films; add revalidates.
    can_add: bool
    # Known release date on or before the user's local date. Upcoming and
    # unknown-date films can be saved but are not Tonight-eligible (ADR 005).
    released: bool


class TraitsOut(BaseModel):
    """Optional enrichment arrives later (P6); unknown until then."""

    pace: float | None = None
    complexity: float | None = None
    heaviness: float | None = None
    source: str | None = None


class MovieDetails(MovieSummary):
    release_date: date | None
    overview: str | None
    original_title: str | None
    original_language: str | None
    vote_count: int | None
    metadata_fetched_at: datetime | None
    stale: bool
    traits: TraitsOut


class SearchResponse(BaseModel):
    page: int
    total_pages: int
    results: list[MovieSummary]


class GenresResponse(BaseModel):
    items: list[GenreOut]
    version: str


class ProviderOut(BaseModel):
    id: int
    name: str
    logo_url: str | None


class AvailabilityResponse(BaseModel):
    """JustWatch data via TMDB for the caller's region; region null when it
    can't be determined. Display-only (ADR 007)."""

    tmdb_id: int
    region: str | None
    link: str | None
    streaming: list[ProviderOut]
    free: list[ProviderOut]
    rent: list[ProviderOut]
    buy: list[ProviderOut]
    fetched_at: datetime | None
    stale: bool


class RegionOut(BaseModel):
    code: str
    name: str


class RegionsResponse(BaseModel):
    items: list[RegionOut]
