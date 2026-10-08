import uuid
from datetime import date, datetime
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

from app.movies.schemas import GenreOut

NextState = Literal["up_next", "not_aired", "caught_up", "completed", "unavailable"]

LIMITATIONS = (
    "Specials aren't included yet. Cinemé follows TMDB's standard season and episode order; "
    "some shows, especially anime, may be ordered differently where you watch."
)


class SeriesSummary(BaseModel):
    tmdb_id: int
    name: str
    year: int | None
    status: str | None
    genre_ids: list[int]
    genres: list[GenreOut]
    poster_url: str | None
    vote_average: float | None = None
    can_add: bool


class EpisodeOut(BaseModel):
    season_number: int
    episode_number: int
    name: str | None
    air_date: date | None
    runtime_minutes: int | None


class NextOut(BaseModel):
    state: NextState
    episode: EpisodeOut | None


class ProgressOut(BaseModel):
    season: int
    episode: int
    version: int


class SeriesEntryOut(BaseModel):
    """A series on the caller's watchlist. `progress` is null until something
    is watched or set; `next` is derived from it and the cached episodes."""

    media_type: Literal["series"] = "series"
    id: uuid.UUID
    series: SeriesSummary
    added_at: datetime
    progress: ProgressOut | None
    progress_version: int
    next: NextOut
    series_rating: int | None


class TvSearchResponse(BaseModel):
    page: int
    total_pages: int
    results: list[SeriesSummary]


class TrendingShowsResponse(BaseModel):
    """At most 12 shows from TMDB's weekly trending list; one page, no cursor."""

    results: list[SeriesSummary]
    in_watchlist: list[int]


class SeriesDetails(BaseModel):
    series: SeriesSummary
    original_name: str | None = None
    overview: str | None
    first_air_date: date | None
    last_air_date: date | None
    origin_countries: list[str]
    season_count: int
    stale: bool
    limitations: str
    entry: SeriesEntryOut | None


class SeasonOut(BaseModel):
    season_number: int
    episodes: list[EpisodeOut]


class SeasonsResponse(BaseModel):
    seasons: list[SeasonOut]
    limitations: str


class LastWatched(BaseModel):
    model_config = ConfigDict(extra="forbid")

    season: int = Field(ge=1, le=1000)
    episode: int = Field(ge=1, le=10000)


class ProgressRequest(BaseModel):
    """`last_watched: null` means "not started"."""

    model_config = ConfigDict(extra="forbid")

    expected_version: int = Field(ge=1)
    last_watched: LastWatched | None


class WatchedEpisodeRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    season: int = Field(ge=1, le=1000)
    episode: int = Field(ge=1, le=10000)
    rating: int | None = Field(default=None, strict=True, ge=1, le=5)


class EpisodeRatingRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    expected_version: int = Field(ge=1)
    rating: int | None = Field(strict=True, ge=1, le=5)


class SeriesRatingRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    rating: int | None = Field(strict=True, ge=1, le=5)


class EpisodeViewingOut(BaseModel):
    id: uuid.UUID
    series: SeriesSummary | None = None
    season_number: int
    episode_number: int
    episode_name: str | None
    watched_at: datetime | None
    recorded_at: datetime
    source: str
    rating: int | None
    version: int
    recommendation_id: uuid.UUID | None


class MutationResponse(BaseModel):
    """Series commands also return the refreshed Today envelope."""

    entry: SeriesEntryOut | None = None
    viewing: EpisodeViewingOut | None = None
    already_recorded: bool | None = None
    today: dict[str, Any]
