import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from app.movies.schemas import MovieSummary

Rating = Literal["loved", "liked", "okay", "disliked"]


class ViewingOut(BaseModel):
    id: uuid.UUID
    movie: MovieSummary
    watched_at: datetime | None
    recorded_at: datetime
    source: str
    rating: Rating | None
    version: int
    recommendation_id: uuid.UUID | None


class ViewingPage(BaseModel):
    items: list[ViewingOut]
    next_cursor: str | None


class RecordViewing(BaseModel):
    model_config = ConfigDict(extra="forbid")

    tmdb_id: int = Field(gt=0, le=2_147_483_647)
    watched_at: datetime | None = None
    rating: Rating | None = None


class RatingPatch(BaseModel):
    model_config = ConfigDict(extra="forbid")

    expected_version: int = Field(ge=1)
    rating: Rating | None
