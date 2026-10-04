"""Today, context and recommendation shapes (API_CONTRACT "Domain response
shapes" and "Today and context"). Unknown request fields are rejected."""

import uuid
from datetime import date, datetime
from typing import Any, Literal, Self

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.movies.schemas import MovieSummary

DesiredExperience = Literal[
    "make_me_laugh", "comfort", "feel_it", "relax", "deep", "exciting", "keep_me_hooked", "surprise"
]
Mood = Literal["down", "tired", "okay", "upbeat"]
GenreIds = list[int]

_STRICT = ConfigDict(extra="forbid")


class SessionContext(BaseModel):
    """Complete accepted context. Mood is display metadata; it never scores."""

    model_config = _STRICT

    current_mood: Mood | None = None
    desired_experience: DesiredExperience
    max_runtime_minutes: int | None = Field(default=None, ge=1, le=600)
    pace: Literal["low", "medium", "high"] | None = None
    complexity_max: float | None = Field(default=None, ge=0, le=1)
    heaviness_max: float | None = Field(default=None, ge=0, le=1)
    prefer_genre_ids: GenreIds = Field(default_factory=list, max_length=20)
    avoid_genre_ids: GenreIds = Field(default_factory=list, max_length=20)

    @model_validator(mode="after")
    def _genre_lists(self) -> Self:
        for ids in (self.prefer_genre_ids, self.avoid_genre_ids):
            if len(set(ids)) != len(ids) or any(i <= 0 for i in ids):
                raise ValueError("genre id lists must be distinct positive ids")
        if set(self.prefer_genre_ids) & set(self.avoid_genre_ids):
            raise ValueError("prefer_genre_ids and avoid_genre_ids must be disjoint")
        self.prefer_genre_ids = sorted(self.prefer_genre_ids)
        self.avoid_genre_ids = sorted(self.avoid_genre_ids)
        return self


class ChooseRequest(BaseModel):
    model_config = _STRICT

    expected_session_version: int = Field(ge=0)
    context: SessionContext | None = None
    continue_after_pause: bool = False


class ContextPatch(BaseModel):
    model_config = _STRICT

    expected_session_version: int = Field(ge=0)
    context: SessionContext


class AcceptRequest(BaseModel):
    model_config = _STRICT

    expected_session_version: int = Field(ge=1)


# P4 supports the temporary reasons plus already_watched (ADR 006);
# never_recommend needs blocks and arrives with P5.
RejectReason = Literal[
    "not_tonight",
    "too_long",
    "wrong_genre",
    "too_serious",
    "want_lighter",
    "already_watched",
    "never_recommend",
    "other",
]


class RejectRequest(BaseModel):
    model_config = _STRICT

    expected_session_version: int = Field(ge=1)
    reason: RejectReason
    details: dict[str, Any] = Field(default_factory=dict)
    note: str | None = Field(default=None, max_length=500)
    choose_another: bool = False


class ReasonOut(BaseModel):
    code: str
    values: dict[str, Any]
    source: str
    # Deterministic template text, stored with the run (ADR 006).
    text: str


class NoMatchSummary(BaseModel):
    candidate_count: int
    primary_exclusion_counts: dict[str, int]
    suggested_actions: list[str]


class RecommendationSummary(BaseModel):
    id: uuid.UUID
    status: str
    movie: MovieSummary | None
    total_score: float | None
    engine_version: str
    explanation: str
    reasons: list[ReasonOut]
    uncertainties: list[ReasonOut]
    created_at: datetime
    no_match_summary: NoMatchSummary | None


class SessionOut(BaseModel):
    id: uuid.UUID
    version: int
    timezone: str
    context: SessionContext
    effective_context: SessionContext
    overridden_fields: list[str]
    rejection_count: int
    attempt_count: int
    completed_at: datetime | None


class FollowUpOut(BaseModel):
    recommendation_id: uuid.UUID
    accepted_local_date: date
    movie: MovieSummary


TodayState = Literal[
    "not_started",
    "ready",
    "offered",
    "accepted",
    "completed",
    "paused",
    "no_match",
    "empty_watchlist",
]


class FollowUpAction(BaseModel):
    model_config = _STRICT
    action: Literal["yes", "no", "not_yet"]


class MarkWatchedRequest(BaseModel):
    model_config = _STRICT
    expected_session_version: int = Field(ge=1)
    rating: int | None = Field(default=None, strict=True, ge=1, le=5)


class FeedbackOut(BaseModel):
    id: uuid.UUID
    reason: str
    created_at: datetime


class ViewingSummary(BaseModel):
    id: uuid.UUID
    movie: MovieSummary
    watched_at: datetime | None
    recorded_at: datetime
    source: str
    rating: int | None
    version: int
    recommendation_id: uuid.UUID | None


class TodayEnvelope(BaseModel):
    state: TodayState
    local_date: date
    session: SessionOut | None
    recommendation: RecommendationSummary | None
    viewing: ViewingSummary | None = None
    follow_up: FollowUpOut | None = None


class RejectResponse(BaseModel):
    feedback: FeedbackOut
    viewing: ViewingSummary | None
    today: TodayEnvelope
    replacement_outcome: Literal["selected", "no_match", "paused", "daily_limit", "not_requested"]


class HistoryItem(RecommendationSummary):
    local_date: date
    timezone: str
    desired_experience: DesiredExperience


class HistoryPage(BaseModel):
    items: list[HistoryItem]
    next_cursor: str | None


class FeedbackDetail(BaseModel):
    reason: str
    details: dict[str, Any]
    note: str | None
    created_at: datetime


class Breakdown(BaseModel):
    components: dict[str, float]
    weights: dict[str, float]
    contributions: dict[str, float]


class RecommendationDetail(BaseModel):
    recommendation: RecommendationSummary
    context: SessionContext
    effective_context: SessionContext
    feedback: FeedbackDetail | None
    breakdown: Breakdown | None
    config_version: str


class ExclusionSummary(BaseModel):
    candidate_count: int
    eligible_count: int
    primary_exclusion_counts: dict[str, int]


class ComparisonResponse(BaseModel):
    engine_version: str
    config_version: str
    config_hash: str
    evaluated_at: datetime
    winner: dict[str, Any] | None
    top_candidates: list[dict[str, Any]]
    exclusion_summary: ExclusionSummary
    comparisons_truncated: bool
