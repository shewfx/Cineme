"""Display helpers shared by the series API and Tonight (no service imports)."""

from collections.abc import Sequence

from app.movies.provider import poster_url
from app.movies.schemas import GenreOut

from . import episodes
from .models import Series
from .schemas import SeriesSummary


def genres(ids: Sequence[int], names: dict[int, str]) -> list[GenreOut]:
    return [GenreOut(id=i, name=names[i]) for i in ids if i in names]


def summary(series: Series, names: dict[int, str], base: str) -> SeriesSummary:
    return SeriesSummary(
        tmdb_id=series.tmdb_id,
        name=series.name,
        year=series.first_air_date.year if series.first_air_date else None,
        status=series.status,
        genre_ids=list(series.genre_ids),
        genres=genres(series.genre_ids, names),
        poster_url=poster_url(base, series.poster_path),
        vote_average=float(series.vote_average) if series.vote_average is not None else None,
        can_add=series.metadata_status == "ready" and not series.adult,
    )


def episode_card(
    series: Series, ep: episodes.Ep, names: dict[int, str], base: str, *, continues: bool
) -> dict[str, object]:
    """Snapshot of an episode pick: the show plus the one episode."""
    return {
        "kind": "episode",
        "series": summary(series, names, base).model_dump(mode="json"),
        "season_number": ep.season,
        "episode_number": ep.episode,
        "name": ep.name,
        "air_date": ep.air_date.isoformat() if ep.air_date else None,
        "runtime_minutes": ep.runtime_minutes,
        "continues_series": continues,
    }
