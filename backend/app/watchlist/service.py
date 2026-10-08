"""Per-user watchlist inventory. Membership means eligibility, not taste:
nothing here touches preferences or learning."""

import base64
import binascii
import json
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Literal

from sqlalchemy import (
    ColumnElement,
    Integer,
    and_,
    case,
    cast,
    func,
    literal,
    or_,
    select,
    union_all,
)
from sqlalchemy.orm import Session

from app.core import idempotency
from app.core.errors import AppError
from app.movies import service as movies
from app.movies.models import Movie
from app.movies.provider import MovieMetadataProvider
from app.recommendations import service as today
from app.series import service as series_service
from app.series.models import Series, SeriesEntry
from app.series.schemas import SeriesEntryOut
from app.users.service import lock_user
from app.viewings.models import Viewing

from .models import WatchlistEntry
from .schemas import AddResponse, WatchlistItem, WatchlistPage

ACTIVE_LIMIT = 500


WatchlistSort = Literal[
    "added_desc",
    "added_asc",
    "title_asc",
    "title_desc",
    "year_desc",
    "year_asc",
    "runtime_asc",
    "runtime_desc",
]
DEFAULT_SORT: WatchlistSort = "added_desc"

# One sort key: a SQL expression, its direction and how to read it back from a
# cursor. Unknown year/runtime sort LAST in both directions through a leading
# "is unknown" flag, so ordering is total and deterministic; the entry id is
# always the final tie-breaker.
_Key = tuple[ColumnElement[Any], bool, Callable[[Any], Any]]


@dataclass(frozen=True)
class _Cols:
    """The sortable columns of one result set: the movie tables on their own,
    or the movie/show union."""

    added: ColumnElement[Any]
    id: ColumnElement[Any]
    title: ColumnElement[Any]
    year_unknown: ColumnElement[Any]
    year: ColumnElement[Any]
    runtime_unknown: ColumnElement[Any]
    runtime: ColumnElement[Any]


_MOVIE_COLS = _Cols(
    added=WatchlistEntry.added_at.expression,
    id=WatchlistEntry.id.expression,
    title=func.lower(Movie.title),
    year_unknown=case((Movie.release_date.is_(None), 1), else_=0),
    year=func.coalesce(func.extract("year", Movie.release_date), 0),
    runtime_unknown=case((Movie.runtime_minutes.is_(None), 1), else_=0),
    runtime=func.coalesce(Movie.runtime_minutes, 0),
)


def _key(expr: ColumnElement[Any], asc: bool, parse: Callable[[Any], Any]) -> _Key:
    return (expr, asc, parse)


def _sort_keys(sort: WatchlistSort, c: _Cols = _MOVIE_COLS) -> list[_Key]:
    asc = sort.endswith("_asc")
    added = _key(c.added, asc, datetime.fromisoformat)
    ident = _key(c.id, asc, uuid.UUID)
    title_asc = _key(c.title, True, str)
    ident_asc = _key(c.id, True, uuid.UUID)
    match sort:
        case "added_desc" | "added_asc":
            return [added, ident]
        case "title_asc" | "title_desc":
            return [_key(c.title, asc, str), ident]
        case "year_desc" | "year_asc":
            return [_key(c.year_unknown, True, int), _key(c.year, asc, int), title_asc, ident_asc]
        case _:
            return [
                _key(c.runtime_unknown, True, int),
                _key(c.runtime, asc, int),
                title_asc,
                ident_asc,
            ]


def _encode_cursor(sort: WatchlistSort, values: list[Any]) -> str:
    raw = json.dumps({"s": sort, "v": [str(v) if not isinstance(v, int) else v for v in values]})
    return base64.urlsafe_b64encode(raw.encode()).decode().rstrip("=")


def _decode_cursor(cursor: str, sort: WatchlistSort, keys: list[_Key]) -> list[Any]:
    try:
        raw = json.loads(base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)).decode())
        if raw["s"] != sort or len(raw["v"]) != len(keys):
            raise ValueError("cursor belongs to another sort")
        return [parse(v) for (_, _, parse), v in zip(keys, raw["v"], strict=True)]
    except (ValueError, KeyError, TypeError, binascii.Error, UnicodeDecodeError) as e:
        raise AppError(
            422, "VALIDATION_ERROR", "Invalid cursor.", details={"fields": ["cursor"]}
        ) from e


def _after(keys: list[_Key], values: list[Any]) -> ColumnElement[bool]:
    """Keyset predicate: rows strictly after the cursor row in sort order."""
    branches = []
    for i, (expr, asc, _) in enumerate(keys):
        ties = [keys[j][0] == values[j] for j in range(i)]
        branches.append(and_(*ties, expr > values[i] if asc else expr < values[i]))
    return or_(*branches)


def _escape_like(text: str) -> str:
    return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _item(
    entry: WatchlistEntry, movie: Movie, names: dict[int, str], base: str, local: Any
) -> WatchlistItem:
    return WatchlistItem(
        id=entry.id,
        movie=movies.summary(movie, names, base, local),
        added_at=entry.added_at,
        source_type=entry.source_type,
    )


def list_entries(
    session: Session,
    provider: MovieMetadataProvider,
    user_id: uuid.UUID,
    limit: int,
    cursor: str | None,
    q: str | None,
    sort: WatchlistSort = DEFAULT_SORT,
    media: Literal["all", "movies", "shows"] = "movies",
) -> WatchlistPage:
    """Active entries in the requested order (default: added_at DESC, id DESC).
    Sorting and keyset pagination happen in SQL, so a page boundary never
    reorders films. Reads only this user's rows and the local cache: works
    while TMDB is down. `media` other than movies lists shows (and movies) from
    one union with the same total order."""
    if media != "movies":
        return _list_union(session, provider, user_id, limit, cursor, q, sort, media)
    local = movies.local_today(session, user_id)
    keys = _sort_keys(sort)
    stmt = (
        select(WatchlistEntry, Movie, *(expr.label(f"k{i}") for i, (expr, _, _) in enumerate(keys)))
        .join(Movie, Movie.tmdb_id == WatchlistEntry.movie_id)
        .where(WatchlistEntry.user_id == user_id, WatchlistEntry.status == "active")
        .order_by(*(expr.asc() if asc else expr.desc() for expr, asc, _ in keys))
        .limit(limit + 1)
    )
    if cursor:
        stmt = stmt.where(_after(keys, _decode_cursor(cursor, sort, keys)))
    if q:
        stmt = stmt.where(Movie.title.ilike(f"%{_escape_like(q)}%", escape="\\"))
    rows = session.execute(stmt).all()
    session.rollback()
    names = movies.genre_names(provider)  # cached in process; optional
    base = provider.image_base()
    page = rows[:limit]
    next_cursor = _encode_cursor(sort, list(page[-1][2:])) if len(rows) > limit else None
    return WatchlistPage(
        items=[_item(r[0], r[1], names, base, local) for r in page], next_cursor=next_cursor
    )


def _list_union(
    session: Session,
    provider: MovieMetadataProvider,
    user_id: uuid.UUID,
    limit: int,
    cursor: str | None,
    q: str | None,
    sort: WatchlistSort,
    media: Literal["all", "movies", "shows"],
) -> WatchlistPage:
    local = movies.local_today(session, user_id)
    like = f"%{_escape_like(q)}%" if q else None
    parts = []
    if media in ("all", "movies"):
        m = (
            select(
                WatchlistEntry.id.label("id"),
                literal("movie").label("kind"),
                WatchlistEntry.added_at.label("added_at"),
                func.lower(Movie.title).label("title"),
                case((Movie.release_date.is_(None), 1), else_=0).label("year_unknown"),
                cast(func.coalesce(func.extract("year", Movie.release_date), 0), Integer).label(
                    "year"
                ),
                case((Movie.runtime_minutes.is_(None), 1), else_=0).label("runtime_unknown"),
                cast(func.coalesce(Movie.runtime_minutes, 0), Integer).label("runtime"),
            )
            .join(Movie, Movie.tmdb_id == WatchlistEntry.movie_id)
            .where(WatchlistEntry.user_id == user_id, WatchlistEntry.status == "active")
        )
        if like:
            m = m.where(Movie.title.ilike(like, escape="\\"))
        parts.append(m)
    if media in ("all", "shows"):
        sh = (
            select(
                SeriesEntry.id.label("id"),
                literal("series").label("kind"),
                SeriesEntry.added_at.label("added_at"),
                func.lower(Series.name).label("title"),
                case((Series.first_air_date.is_(None), 1), else_=0).label("year_unknown"),
                cast(func.coalesce(func.extract("year", Series.first_air_date), 0), Integer).label(
                    "year"
                ),
                # A show has no single runtime: it sorts with the unknowns.
                literal(1).label("runtime_unknown"),
                literal(0).label("runtime"),
            )
            .join(Series, Series.tmdb_id == SeriesEntry.series_id)
            .where(SeriesEntry.user_id == user_id, SeriesEntry.status == "active")
        )
        if like:
            sh = sh.where(Series.name.ilike(like, escape="\\"))
        parts.append(sh)
    u = union_all(*parts).subquery()
    cols = _Cols(
        added=u.c.added_at,
        id=u.c.id,
        title=u.c.title,
        year_unknown=u.c.year_unknown,
        year=u.c.year,
        runtime_unknown=u.c.runtime_unknown,
        runtime=u.c.runtime,
    )
    keys = _sort_keys(sort, cols)
    stmt = (
        select(u.c.id, u.c.kind, *(expr.label(f"k{i}") for i, (expr, _, _) in enumerate(keys)))
        .order_by(*(expr.asc() if asc else expr.desc() for expr, asc, _ in keys))
        .limit(limit + 1)
    )
    if cursor:
        stmt = stmt.where(_after(keys, _decode_cursor(cursor, sort, keys)))
    rows = session.execute(stmt).all()
    page = rows[:limit]
    next_cursor = _encode_cursor(sort, list(page[-1][2:])) if len(rows) > limit else None
    movie_ids = [r[0] for r in page if r[1] == "movie"]
    show_ids = [r[0] for r in page if r[1] == "series"]
    movie_rows = (
        {
            e.id: (e, mv)
            for e, mv in session.execute(
                select(WatchlistEntry, Movie)
                .join(Movie, Movie.tmdb_id == WatchlistEntry.movie_id)
                .where(WatchlistEntry.id.in_(movie_ids))
            ).all()
        }
        if movie_ids
        else {}
    )
    show_rows = (
        {
            e.id: (e, sr)
            for e, sr in session.execute(
                select(SeriesEntry, Series)
                .join(Series, Series.tmdb_id == SeriesEntry.series_id)
                .where(SeriesEntry.id.in_(show_ids))
            ).all()
        }
        if show_ids
        else {}
    )
    names = movies.genre_names(provider)
    base = provider.image_base()
    shows_out = {
        o.id: o
        for o in series_service.entries_out(
            session, user_id, list(show_rows.values()), names, base, local
        )
    }
    session.rollback()
    items: list[WatchlistItem | SeriesEntryOut] = []
    for row_id, kind, *_ in page:
        if kind == "movie":
            e, mv = movie_rows[row_id]
            items.append(_item(e, mv, names, base, local))
        else:
            items.append(shows_out[row_id])
    return WatchlistPage(items=items, next_cursor=next_cursor)


def add(
    session: Session,
    provider: MovieMetadataProvider,
    user_id: uuid.UUID,
    tmdb_id: int,
    key: uuid.UUID,
    media_type: Literal["movie", "series"] = "movie",
) -> tuple[int, dict[str, Any]]:
    """Returns (status, body). Duplicate active add -> 200 already_present;
    new or restored -> 201. Restoring resets added_at."""
    if media_type == "series":
        return series_service.add(session, provider, user_id, tmdb_id, key)
    operation = "POST /api/v1/watchlist"
    digest = idempotency.request_hash({"tmdb_id": tmdb_id})

    # Preflight: an identical committed retry is replayed without network.
    replay = idempotency.lookup(session, user_id, key, operation, digest)
    session.rollback()
    if replay is not None:
        return replay.status, replay.body

    movies.details_cached(session, provider, tmdb_id)  # network outside the lock
    names = movies.genre_names(provider)
    base = provider.image_base()

    with session.begin():
        user = lock_user(session, user_id)
        replay = idempotency.lookup(session, user_id, key, operation, digest)
        if replay is not None:
            return replay.status, replay.body
        local = movies.local_today(session, user_id)
        movie = session.get(Movie, tmdb_id)
        if session.scalar(
            select(Viewing.id).where(Viewing.user_id == user_id, Viewing.movie_id == tmdb_id)
        ):
            raise AppError(409, "MOVIE_ALREADY_WATCHED", "You've already watched this film.")
        if movie is None or movie.metadata_status != "ready" or not movies.can_add(movie.adult):
            raise AppError(422, "MOVIE_INELIGIBLE", "This film can't be added to Cinemé.")
        entry = session.scalar(
            select(WatchlistEntry).where(
                WatchlistEntry.user_id == user_id, WatchlistEntry.movie_id == tmdb_id
            )
        )
        now = today.utc_now()
        if entry is not None and entry.status == "active":
            status, already = 200, True
        else:
            active = series_service.active_total(session, user_id)
            if active >= ACTIVE_LIMIT:
                raise AppError(
                    409,
                    "WATCHLIST_LIMIT",
                    f"Your watchlist is full ({ACTIVE_LIMIT} films). Remove one to add another.",
                )
            if entry is None:
                entry = WatchlistEntry(
                    id=uuid.uuid4(),
                    user_id=user_id,
                    movie_id=tmdb_id,
                    status="active",
                    added_at=now,
                    source_type="manual",
                )
                session.add(entry)
            else:  # restore an archived entry; its age starts again
                entry.status = "active"
                entry.removed_at = None
                entry.added_at = now
                entry.updated_at = now
            status, already = 201, False
            today.on_watchlist_added(session, user, now)
        session.flush()
        body = AddResponse(
            entry=_item(entry, movie, names, base, local),
            already_present=already,
            today=today.envelope(session, user, now),
        ).model_dump(mode="json")
        idempotency.store(session, user_id, key, operation, digest, status, body)
    return status, body


def remove(
    session: Session, user_id: uuid.UUID, entry_id: uuid.UUID, key: uuid.UUID
) -> tuple[int, dict[str, Any]]:
    """Archives the caller's entry. Someone else's or unknown id -> 404, never
    a leaked 403. Already removed succeeds."""
    operation = f"DELETE /api/v1/watchlist/{entry_id}"
    digest = idempotency.request_hash({})
    with session.begin():
        user = lock_user(session, user_id)
        replay = idempotency.lookup(session, user_id, key, operation, digest)
        if replay is not None:
            return replay.status, replay.body
        entry = session.scalar(
            select(WatchlistEntry)
            .where(WatchlistEntry.id == entry_id, WatchlistEntry.user_id == user_id)
            .with_for_update()
        )
        if entry is None:
            show = session.scalar(
                select(SeriesEntry)
                .where(SeriesEntry.id == entry_id, SeriesEntry.user_id == user_id)
                .with_for_update()
            )
            if show is None:
                raise AppError(404, "NOT_FOUND", "That watchlist entry was not found.")
            if show.status == "active":
                now = today.utc_now()
                show.status = "removed"
                show.removed_at = now
                show.updated_at = now
                today.on_series_removed(session, user, show.series_id, now)
            session.flush()
            show_body: dict[str, Any] = {"removed": True, "today": today.envelope(session, user)}
            idempotency.store(session, user_id, key, operation, digest, 200, show_body)
            return 200, show_body
        if entry.status == "active":
            now = today.utc_now()
            entry.status = "removed"
            entry.removed_at = now
            entry.updated_at = now
            today.on_watchlist_removed(session, user, entry.movie_id, now)
        session.flush()
        body: dict[str, Any] = {"removed": True, "today": today.envelope(session, user)}
        idempotency.store(session, user_id, key, operation, digest, 200, body)
    return 200, body
