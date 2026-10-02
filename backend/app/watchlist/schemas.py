import uuid
from datetime import datetime
from typing import Any

from pydantic import BaseModel, ConfigDict, Field

from app.movies.schemas import MovieSummary


class WatchlistItem(BaseModel):
    id: uuid.UUID
    movie: MovieSummary
    added_at: datetime
    source_type: str


class WatchlistPage(BaseModel):
    items: list[WatchlistItem]
    next_cursor: str | None


class AddRequest(BaseModel):
    """Only the film's identity; ownership comes from the token."""

    model_config = ConfigDict(extra="forbid")

    tmdb_id: int = Field(gt=0, le=2_147_483_647)


class AddResponse(BaseModel):
    """`today` arrived with Today in P4 (ADR 004)."""

    entry: WatchlistItem
    already_present: bool
    today: dict[str, Any]


class RemoveResponse(BaseModel):
    removed: bool
    today: dict[str, Any]
