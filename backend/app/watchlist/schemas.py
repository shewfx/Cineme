import uuid
from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

from app.movies.schemas import MovieSummary
from app.series.schemas import SeriesEntryOut


class WatchlistItem(BaseModel):
    media_type: Literal["movie"] = "movie"
    id: uuid.UUID
    movie: MovieSummary
    added_at: datetime
    source_type: str


class WatchlistPage(BaseModel):
    """Movies for clients without series support; movies and shows (each item
    names its `media_type`) for clients that declare it."""

    items: list[WatchlistItem | SeriesEntryOut]
    next_cursor: str | None


class AddRequest(BaseModel):
    """Only the film's identity; ownership comes from the token."""

    model_config = ConfigDict(extra="forbid")

    tmdb_id: int = Field(gt=0, le=2_147_483_647)
    # Absent means a movie, so every existing client request is unchanged.
    media_type: Literal["movie", "series"] = "movie"


class AddResponse(BaseModel):
    """`today` arrived with Today in P4 (ADR 004)."""

    entry: WatchlistItem | SeriesEntryOut
    already_present: bool
    today: dict[str, Any]


class RemoveResponse(BaseModel):
    removed: bool
    today: dict[str, Any]
