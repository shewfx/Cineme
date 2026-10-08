"""The next-episode rule (ADR 011), pure: no database, clock or network.

Regular episodes are ordered by (season >= 1, episode). With a saved progress
pointer the series' next episode is the first regular episode strictly after
it (or the first one when nothing is watched). Only that one episode is ever
considered: later episodes are never offered, so nothing is silently skipped.
"""

from dataclasses import dataclass
from datetime import date

ENDED_STATUSES = frozenset({"Ended", "Canceled"})

UP_NEXT = "up_next"
NOT_AIRED = "not_aired"
CAUGHT_UP = "caught_up"
COMPLETED = "completed"
UNAVAILABLE = "unavailable"


@dataclass(frozen=True)
class Ep:
    season: int
    episode: int
    name: str | None = None
    air_date: date | None = None
    runtime_minutes: int | None = None

    @property
    def key(self) -> tuple[int, int]:
        return (self.season, self.episode)


@dataclass(frozen=True)
class Next:
    """`state` is one of up_next, not_aired, caught_up, completed, unavailable.
    `episode` is set for up_next and not_aired."""

    state: str
    episode: Ep | None = None


def has_aired(air_date: date | None, today: date) -> bool:
    """Unknown air dates never count as aired."""
    return air_date is not None and air_date <= today


def next_state(first_after: Ep | None, *, has_data: bool, status: str | None, today: date) -> Next:
    """`first_after` is the first regular episode after the progress pointer
    (None when there is none); `has_data` says episodes were ever loaded."""
    if not has_data:
        return Next(UNAVAILABLE)
    if first_after is None:
        return Next(COMPLETED if status in ENDED_STATUSES else CAUGHT_UP)
    if has_aired(first_after.air_date, today):
        return Next(UP_NEXT, first_after)
    return Next(NOT_AIRED, first_after)


def is_after(season: int, episode: int, progress: tuple[int, int] | None) -> bool:
    return progress is None or (season, episode) > progress
