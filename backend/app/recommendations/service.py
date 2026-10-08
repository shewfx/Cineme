"""Today: one daily session per user and local date, ONE current pick, and
the commands that change it (API_CONTRACT "Today and context",
"Recommendation actions and history").

Every mutation locks the caller's users row first, replays an identical
idempotent retry, then checks the session version. Selection runs the pure
engine on data already in PostgreSQL: no network inside the lock. GET never
creates a session or selects a movie.
"""

import base64
import binascii
import json
import uuid
from collections.abc import Callable
from datetime import UTC, date, datetime, time, timedelta
from decimal import Decimal
from typing import Any
from zoneinfo import ZoneInfo

from sqlalchemy import func, select, tuple_
from sqlalchemy.orm import Session

from app.core import idempotency
from app.core.errors import AppError
from app.core.features import series_enabled
from app.movies import service as movies
from app.movies.models import Movie
from app.series import display as series_display
from app.series import episodes as series_episodes
from app.series import history as series_history
from app.series.models import (
    EpisodeViewing,
    Series,
    SeriesBlock,
    SeriesEntry,
)
from app.users.blocks import MovieBlock
from app.users.models import User, UserPreferences
from app.users.service import lock_user
from app.viewings.models import Viewing
from app.watchlist.models import WatchlistEntry

from . import engine, explain
from .models import Recommendation, RecommendationSession, RejectionFeedback
from .schemas import ChooseRequest, ContextPatch, RejectRequest, SessionContext

CONFIG = engine.load_series_config()  # weighted_v2; fails at startup if invalid
PAUSE_AFTER_REJECTIONS = 3
DAILY_ATTEMPT_LIMIT = 20
EVIDENCE_LIMIT_BYTES = 64 * 1024
SCORING_FIELDS = (
    "desired_experience",
    "max_runtime_minutes",
    "pace",
    "complexity_max",
    "heaviness_max",
    "prefer_genre_ids",
    "avoid_genre_ids",
)
LIGHTER_HEAVINESS = 0.35


def utc_now() -> datetime:
    """The only clock read in this module; tests replace it."""
    return datetime.now(UTC)


# --- dates, sessions and context ----------------------------------------------------


def local_date_for(user: User, now: datetime) -> date:
    return now.astimezone(ZoneInfo(user.timezone)).date()


def _day_end(local: date, zone: str) -> datetime:
    """Next local midnight in UTC (DST-aware through zoneinfo)."""
    return datetime.combine(local + timedelta(days=1), time(0), ZoneInfo(zone)).astimezone(UTC)


def _today_session(db: Session, user_id: uuid.UUID, local: date) -> RecommendationSession | None:
    return db.scalar(
        select(RecommendationSession).where(
            RecommendationSession.user_id == user_id, RecommendationSession.local_date == local
        )
    )


def _prefs(db: Session, user_id: uuid.UUID) -> UserPreferences:
    prefs = db.get(UserPreferences, user_id)
    if prefs is None:
        raise AppError(409, "PROFILE_NOT_INITIALIZED", "Your Cinemé profile is not set up yet.")
    return prefs


def effective_context(
    ctx: dict[str, Any], prefs: UserPreferences
) -> tuple[dict[str, Any], list[str]]:
    """Profile limits win: minimum cap, union of avoided genres, blocked ids
    removed from preferred. Returns (effective, overridden field names)."""
    eff = dict(ctx)
    overridden = []
    caps = [c for c in (ctx.get("max_runtime_minutes"), prefs.default_max_runtime_minutes) if c]
    cap = min(caps) if caps else None
    if cap != ctx.get("max_runtime_minutes"):
        overridden.append("max_runtime_minutes")
    eff["max_runtime_minutes"] = cap
    blocked = set(prefs.blocked_genre_ids)
    avoid = sorted(set(ctx.get("avoid_genre_ids", [])) | blocked)
    if avoid != sorted(ctx.get("avoid_genre_ids", [])):
        overridden.append("avoid_genre_ids")
    eff["avoid_genre_ids"] = avoid
    prefer = [g for g in ctx.get("prefer_genre_ids", []) if g not in blocked]
    if prefer != ctx.get("prefer_genre_ids", []):
        overridden.append("prefer_genre_ids")
    eff["prefer_genre_ids"] = prefer
    return eff, overridden


def scoring_key(eff: dict[str, Any]) -> tuple[Any, ...]:
    """Fields that change ranking; current_mood is deliberately absent."""
    return tuple(
        tuple(eff.get(k) or []) if k.endswith("_ids") else eff.get(k) for k in SCORING_FIELDS
    )


def _bump(s: RecommendationSession, now: datetime) -> None:
    s.version += 1
    s.updated_at = now


def _current(db: Session, s: RecommendationSession | None) -> Recommendation | None:
    if s is None or s.current_recommendation_id is None:
        return None
    return db.get(Recommendation, s.current_recommendation_id)


def _clear_pick(
    db: Session,
    s: RecommendationSession,
    now: datetime,
    *,
    movie_id: int | None = None,
    series_id: int | None = None,
) -> bool:
    """Supersede an offered/accepted pick (optionally only for one movie or
    show) and clear the pointer. A no-match row stays terminal; only its
    pointer goes. Returns whether anything changed."""
    current = _current(db, s)
    if current is None:
        return False
    if movie_id is not None and current.movie_id != movie_id:
        return False
    if series_id is not None and current.series_id != series_id:
        return False
    if current.status in ("offered", "accepted"):
        current.status = "superseded"
        current.resolved_at = now
    s.current_recommendation_id = None
    return True


def _counts(db: Session, s: RecommendationSession | None) -> tuple[int, int]:
    """(rejections, attempts) derived from the session's attempts."""
    if s is None:
        return 0, 0
    rows = db.execute(
        select(Recommendation.status, func.count())
        .where(Recommendation.session_id == s.id)
        .group_by(Recommendation.status)
    ).all()
    by_status = {status: n for status, n in rows}
    return by_status.get("rejected", 0), sum(by_status.values())


def _active_count(db: Session, user_id: uuid.UUID) -> int:
    return (
        db.scalar(
            select(func.count())
            .select_from(WatchlistEntry)
            .where(WatchlistEntry.user_id == user_id, WatchlistEntry.status == "active")
        )
        or 0
    )


def _active_series_count(db: Session, user_id: uuid.UUID) -> int:
    return (
        db.scalar(
            select(func.count())
            .select_from(SeriesEntry)
            .where(SeriesEntry.user_id == user_id, SeriesEntry.status == "active")
        )
        or 0
    )


def effective_media(prefs: UserPreferences) -> str:
    """The media Tonight considers. A client that did not declare series
    support always gets movies (ADR 011); the stored preference is untouched."""
    return prefs.tonight_media if series_enabled() else "movies"


def _empty_reason(db: Session, user_id: uuid.UUID, media: str) -> str | None:
    """None when the preferred media has candidates; otherwise why not."""
    movies_n = _active_count(db, user_id) if media in ("movies", "movies_and_shows") else 0
    shows_n = _active_series_count(db, user_id) if media in ("shows", "movies_and_shows") else 0
    if movies_n + shows_n > 0:
        return None
    other = _active_count(db, user_id) + (
        _active_series_count(db, user_id) if series_enabled() else 0
    )
    if other == 0:
        return "none"
    return "no_shows" if media == "shows" else "no_movies"


# --- envelope -------------------------------------------------------------------------


def _iso(t: datetime) -> str:
    return t.astimezone(UTC).isoformat().replace("+00:00", "Z")


def summary(rec: Recommendation) -> dict[str, Any]:
    """RecommendationSummary from the stored snapshot, never current metadata."""
    reasons = rec.reason_data
    snapshot = rec.winner_snapshot
    return {
        "id": str(rec.id),
        "status": rec.status,
        "media_kind": rec.media_kind,
        "movie": snapshot["movie"] if snapshot and rec.media_kind == "movie" else None,
        "episode": snapshot["episode"] if snapshot and rec.media_kind == "episode" else None,
        "total_score": float(round(rec.total_score, 2)) if rec.total_score is not None else None,
        "engine_version": rec.engine_version,
        "explanation": rec.explanation,
        "reasons": reasons.get("reasons", []),
        "uncertainties": reasons.get("uncertainties", []),
        "created_at": _iso(rec.created_at),
        "no_match_summary": rec.no_match_summary,
    }


def _episode_viewing_out(
    db: Session, v: EpisodeViewing, snapshot: dict[str, Any]
) -> dict[str, Any]:
    return {
        "id": str(v.id),
        "movie": None,
        "episode": snapshot["episode"],
        "watched_at": _iso(v.watched_at) if v.watched_at else None,
        "recorded_at": _iso(v.recorded_at),
        "source": v.source,
        "rating": v.rating,
        "version": v.version,
        "recommendation_id": str(v.recommendation_id) if v.recommendation_id else None,
    }


def envelope(db: Session, user: User, now: datetime | None = None) -> dict[str, Any]:
    """TodayEnvelope; state precedence per API_CONTRACT. Read-only. A client
    that did not declare series support never sees an episode pick (ADR 011):
    it is treated as if there were no current pick."""
    now = now or utc_now()
    local = local_date_for(user, now)
    s = _today_session(db, user.id, local)
    current = _current(db, s)
    series_ok = series_enabled()
    if current is not None and current.media_kind == "episode" and not series_ok:
        current = None
    rejections, attempts = _counts(db, s)
    prefs = _prefs(db, user.id)
    media = effective_media(prefs)
    empty_reason = _empty_reason(db, user.id, media)
    done = s is not None and s.completed_at is not None
    if done and (current is not None or series_ok):
        state = "completed"
    elif done:
        state = "ready"
    elif current is not None and current.status in ("offered", "accepted", "watched"):
        state = current.status if current.status != "watched" else "completed"
    elif current is not None and current.status == "no_match":
        state = "no_match"
    elif empty_reason is not None:
        state = "empty_watchlist"
    elif s is None:
        state = "not_started"
    elif rejections >= PAUSE_AFTER_REJECTIONS:
        state = "paused"
    else:
        state = "ready"
    session_out = None
    if s is not None:
        eff, overridden = effective_context(s.context, prefs)
        session_out = {
            "id": str(s.id),
            "version": s.version,
            "timezone": s.timezone_snapshot,
            "context": s.context,
            "effective_context": eff,
            "overridden_fields": overridden,
            "rejection_count": rejections,
            "attempt_count": attempts,
            "completed_at": _iso(s.completed_at) if s.completed_at else None,
        }
    show = current is not None and current.status in ("offered", "accepted", "watched", "no_match")
    viewing_out = None
    if current is not None and current.status == "watched" and current.winner_snapshot is not None:
        if current.media_kind == "episode":
            ev = db.scalar(
                select(EpisodeViewing).where(
                    EpisodeViewing.user_id == user.id,
                    EpisodeViewing.recommendation_id == current.id,
                )
            )
            if ev is not None:
                viewing_out = _episode_viewing_out(db, ev, current.winner_snapshot)
        else:
            viewing = db.scalar(
                select(Viewing).where(
                    Viewing.user_id == user.id,
                    Viewing.recommendation_id == current.id,
                )
            )
            if viewing is not None:
                viewing_out = {
                    "id": str(viewing.id),
                    "movie": current.winner_snapshot["movie"],
                    "episode": None,
                    "watched_at": _iso(viewing.watched_at) if viewing.watched_at else None,
                    "recorded_at": _iso(viewing.recorded_at),
                    "source": viewing.source,
                    "rating": viewing.rating,
                    "version": viewing.version,
                    "recommendation_id": str(viewing.recommendation_id),
                }
    follow_stmt = (
        select(Recommendation, RecommendationSession)
        .join(RecommendationSession, RecommendationSession.id == Recommendation.session_id)
        .where(
            RecommendationSession.user_id == user.id,
            RecommendationSession.local_date < local,
            Recommendation.status == "accepted",
            Recommendation.follow_up_resolved.is_(False),
            (
                Recommendation.follow_up_prompted_on.is_(None)
                | (Recommendation.follow_up_prompted_on < local)
            ),
        )
        .order_by(Recommendation.accepted_at.desc(), Recommendation.id.desc())
        .limit(1)
    )
    if not series_ok:
        follow_stmt = follow_stmt.where(Recommendation.media_kind == "movie")
    prior = db.execute(follow_stmt).first()
    follow_up = None
    if prior is not None and prior[0].winner_snapshot is not None:
        snap = prior[0].winner_snapshot
        follow_up = {
            "recommendation_id": str(prior[0].id),
            "accepted_local_date": prior[1].local_date.isoformat(),
            "media_kind": prior[0].media_kind,
            "movie": snap["movie"] if prior[0].media_kind == "movie" else None,
            "episode": snap["episode"] if prior[0].media_kind == "episode" else None,
        }
    return {
        "state": state,
        "local_date": local.isoformat(),
        "session": session_out,
        "recommendation": summary(current) if show and current is not None else None,
        "viewing": viewing_out,
        "follow_up": follow_up,
        "media": media,
        "empty_reason": empty_reason if state == "empty_watchlist" else None,
    }


# --- selection ------------------------------------------------------------------------


def _candidates(db: Session, user_id: uuid.UUID) -> list[tuple[WatchlistEntry, Movie]]:
    rows = db.execute(
        select(WatchlistEntry, Movie)
        .join(Movie, Movie.tmdb_id == WatchlistEntry.movie_id)
        .where(WatchlistEntry.user_id == user_id, WatchlistEntry.status == "active")
    ).all()
    return [(e, m) for e, m in rows]


def _offer_history(
    db: Session, user_id: uuid.UUID, s: RecommendationSession
) -> tuple[dict[int, datetime], set[int]]:
    """Last offer per movie across all of this user's sessions (one grouped
    query), and the movies already offered in today's session."""
    last = db.execute(
        select(Recommendation.movie_id, func.max(Recommendation.created_at))
        .join(RecommendationSession, RecommendationSession.id == Recommendation.session_id)
        .where(RecommendationSession.user_id == user_id, Recommendation.movie_id.is_not(None))
        .group_by(Recommendation.movie_id)
    ).all()
    tonight = db.scalars(
        select(Recommendation.movie_id).where(
            Recommendation.session_id == s.id, Recommendation.movie_id.is_not(None)
        )
    ).all()
    return {m: t for m, t in last if m is not None}, {m for m in tonight if m is not None}


def _viewing_history(
    db: Session, user_id: uuid.UUID
) -> tuple[
    set[int],
    tuple[tuple[int, ...], ...],
    tuple[int | None, ...],
    tuple[engine.RatedViewing, ...],
]:
    """Known-watched movies, the three most recent viewings (movies and
    episodes) as genre snapshots with their series id, and current movie
    ratings. Episode and series ratings feed nothing."""
    viewings = db.scalars(select(Viewing).where(Viewing.user_id == user_id)).all()
    watched = {v.movie_id for v in viewings}
    movie_rows = db.execute(
        select(
            func.coalesce(Viewing.watched_at, Viewing.recorded_at).label("at"),
            Viewing.genre_ids_snapshot,
        )
        .where(Viewing.user_id == user_id, func.cardinality(Viewing.genre_ids_snapshot) > 0)
        .order_by(func.coalesce(Viewing.watched_at, Viewing.recorded_at).desc(), Viewing.id.desc())
        .limit(3)
    ).all()
    episode_rows = db.execute(
        select(
            func.coalesce(EpisodeViewing.watched_at, EpisodeViewing.recorded_at).label("at"),
            EpisodeViewing.genre_ids_snapshot,
            EpisodeViewing.series_id,
        )
        .where(
            EpisodeViewing.user_id == user_id,
            func.cardinality(EpisodeViewing.genre_ids_snapshot) > 0,
        )
        .order_by(
            func.coalesce(EpisodeViewing.watched_at, EpisodeViewing.recorded_at).desc(),
            EpisodeViewing.id.desc(),
        )
        .limit(3)
    ).all()
    merged: list[tuple[datetime, tuple[int, ...], int | None]] = [
        (r.at, tuple(r.genre_ids_snapshot), None) for r in movie_rows
    ] + [(r.at, tuple(r.genre_ids_snapshot), r.series_id) for r in episode_rows]
    merged.sort(key=lambda t: t[0], reverse=True)
    top = merged[:3]
    rated = tuple(
        engine.RatedViewing(tuple(v.genre_ids_snapshot), v.rating)
        for v in viewings
        if v.rating is not None
    )
    return watched, tuple(t[1] for t in top), tuple(t[2] for t in top), rated


def _episode_offers(
    db: Session, user_id: uuid.UUID, s: RecommendationSession
) -> tuple[dict[tuple[int, int, int], datetime], set[int]]:
    """Last offer per episode across the user's sessions, and the series
    already offered in today's session."""
    last = db.execute(
        select(
            Recommendation.series_id,
            Recommendation.season_number,
            Recommendation.episode_number,
            func.max(Recommendation.created_at),
        )
        .join(RecommendationSession, RecommendationSession.id == Recommendation.session_id)
        .where(RecommendationSession.user_id == user_id, Recommendation.series_id.is_not(None))
        .group_by(
            Recommendation.series_id, Recommendation.season_number, Recommendation.episode_number
        )
    ).all()
    tonight = db.scalars(
        select(Recommendation.series_id).where(
            Recommendation.session_id == s.id, Recommendation.series_id.is_not(None)
        )
    ).all()
    return (
        {
            (sid, sn, en): t
            for sid, sn, en, t in last
            if sid is not None and sn is not None and en is not None
        },
        {x for x in tonight if x is not None},
    )


def _confirmed_watches(
    db: Session, user: User, local: date, window_days: int
) -> dict[int, tuple[int, date]]:
    """Per series: (number of confirmed episode watches in the continuity
    window, local date of the newest). Only recorded watches count: showing
    or accepting a pick, and progress corrections, never do."""
    zone = ZoneInfo(user.timezone)
    since = datetime.combine(local - timedelta(days=window_days + 1), time(0), zone)
    rows = db.execute(
        select(
            EpisodeViewing.series_id,
            func.coalesce(EpisodeViewing.watched_at, EpisodeViewing.recorded_at),
        ).where(
            EpisodeViewing.user_id == user.id,
            func.coalesce(EpisodeViewing.watched_at, EpisodeViewing.recorded_at) >= since,
        )
    ).all()
    out: dict[int, tuple[int, date]] = {}
    for series_id, at in rows:
        day = at.astimezone(zone).date()
        if not local - timedelta(days=window_days) <= day <= local:
            continue
        count, newest = out.get(series_id, (0, day))
        out[series_id] = (count + 1, max(newest, day))
    return out


def record_viewing(
    db: Session,
    user: User,
    movie: Movie,
    watched_at: datetime | None,
    now: datetime,
    *,
    source: str = "already_watched",
    rating: int | None = None,
    recommendation_id: uuid.UUID | None = None,
) -> Viewing:
    """Canonical viewing upsert used by manual and recommendation actions.
    Reuses the one user/movie record and archives any active inventory row in
    the same transaction. The caller supplies the truthful date and source."""
    viewing = db.scalar(
        select(Viewing).where(Viewing.user_id == user.id, Viewing.movie_id == movie.tmdb_id)
    )
    if viewing is None:
        viewing = Viewing(
            id=uuid.uuid4(),
            user_id=user.id,
            movie_id=movie.tmdb_id,
            watched_at=watched_at,
            recorded_at=now,
            source=source,
            rating=rating,
            genre_ids_snapshot=list(movie.genre_ids),
            recommendation_id=recommendation_id,
            version=1,
            updated_at=now,
        )
        db.add(viewing)
    entry = db.scalar(
        select(WatchlistEntry).where(
            WatchlistEntry.user_id == user.id,
            WatchlistEntry.movie_id == movie.tmdb_id,
            WatchlistEntry.status == "active",
        )
    )
    if entry is not None:
        entry.status = "removed"
        entry.removed_at = now
        entry.updated_at = now
    db.flush()
    return viewing


def viewing_summary(
    v: Viewing, movie: Movie, names: dict[int, str], image_base: str
) -> dict[str, Any]:
    return {
        "id": str(v.id),
        "movie": movies.summary(movie, names, image_base, v.recorded_at.date()).model_dump(
            mode="json"
        ),
        "watched_at": _iso(v.watched_at) if v.watched_at else None,
        "recorded_at": _iso(v.recorded_at),
        "source": v.source,
        "rating": v.rating,
        "version": v.version,
        "recommendation_id": str(v.recommendation_id) if v.recommendation_id else None,
    }


def _dec(x: float | None) -> Decimal | None:
    return None if x is None else Decimal(str(x))


def _scoring_inputs(c: engine.Candidate) -> dict[str, Any]:
    inputs: dict[str, Any] = {
        "added_at": c.added_at.isoformat(),
        "release_date": c.release_date.isoformat() if c.release_date else None,
        "runtime_minutes": c.runtime_minutes,
        "genre_ids": list(c.genre_ids),
        "vote_average": str(c.vote_average) if c.vote_average is not None else None,
        "vote_count": c.vote_count,
        "last_offered_at": c.last_offered_at.isoformat() if c.last_offered_at else None,
        "traits": {"pace": None, "complexity": None, "heaviness": None, "source": None},
    }
    if c.kind == "series":
        inputs["season_number"] = c.season_number
        inputs["episode_number"] = c.episode_number
        inputs["confirmed_watches"] = c.confirmed_watch_count
        inputs["last_confirmed_watch"] = (
            c.last_confirmed_watch.isoformat() if c.last_confirmed_watch else None
        )
    return inputs


def _scored_record(s: engine.Scored, item: dict[str, Any]) -> dict[str, Any]:
    return {
        "episode" if s.candidate.kind == "series" else "movie": item,
        "rank": s.rank,
        "total_score": f"{s.total:.6f}",
        "components": {k: f"{v:.6f}" for k, v in s.components.items()},
        "contributions": {k: f"{v:.6f}" for k, v in s.contributions.items()},
        "scoring_inputs": _scoring_inputs(s.candidate),
    }


def _series_candidates(
    db: Session, user: User, s: RecommendationSession, local: date
) -> tuple[list[engine.Candidate], dict[int, tuple[Series, series_episodes.Ep | None]]]:
    """One candidate per active show: its single next episode, or the reason
    it has none. Eligibility itself is the engine's job."""
    rows = db.execute(
        select(SeriesEntry, Series)
        .join(Series, Series.tmdb_id == SeriesEntry.series_id)
        .where(SeriesEntry.user_id == user.id, SeriesEntry.status == "active")
    ).all()
    if not rows:
        return [], {}
    nxt = series_history.next_candidates(db, user.id)
    blocked = set(db.scalars(select(SeriesBlock.series_id).where(SeriesBlock.user_id == user.id)))
    last_offer, tonight = _episode_offers(db, user.id, s)
    window = CONFIG.continuity.window_days if CONFIG.continuity else 0
    watches = _confirmed_watches(db, user, local, window) if window else {}
    candidates: list[engine.Candidate] = []
    meta: dict[int, tuple[Series, series_episodes.Ep | None]] = {}
    for entry, series in rows:
        state = series_episodes.next_state(
            nxt.get(series.tmdb_id),
            has_data=series.episodes_fetched_at is not None,
            status=series.status,
            today=local,
        )
        ep = state.episode
        count, newest = watches.get(series.tmdb_id, (0, None))
        candidates.append(
            engine.Candidate(
                tmdb_id=series.tmdb_id,
                added_at=entry.added_at,
                release_date=series.first_air_date,
                runtime_minutes=ep.runtime_minutes if ep else None,
                genre_ids=tuple(series.genre_ids),
                adult=series.adult,
                metadata_ready=series.metadata_status == "ready",
                vote_average=series.vote_average,
                vote_count=series.vote_count,
                last_offered_at=last_offer.get((series.tmdb_id, ep.season, ep.episode))
                if ep
                else None,
                offered_this_session=series.tmdb_id in tonight,
                blocked=series.tmdb_id in blocked,
                kind="series",
                season_number=ep.season if ep else None,
                episode_number=ep.episode if ep else None,
                episode_state=state.state,
                confirmed_watch_count=count,
                last_confirmed_watch=newest,
            )
        )
        meta[series.tmdb_id] = (series, ep)
    return candidates, meta


def select_one(
    db: Session,
    user: User,
    s: RecommendationSession,
    now: datetime,
    names: dict[int, str],
    image_base: str,
) -> Recommendation:
    """Runs the engine over the active watchlist (the media the user chose
    for Tonight) and persists ONE attempt (a pick or an honest no-match) with
    bounded evidence."""
    local = s.local_date
    prefs = _prefs(db, user.id)
    eff, _ = effective_context(s.context, prefs)
    media = effective_media(prefs)
    want_movies = media in ("movies", "movies_and_shows")
    want_shows = media in ("shows", "movies_and_shows")
    rows = _candidates(db, user.id) if want_movies else []
    last_offer, tonight = _offer_history(db, user.id, s)
    watched, recent, recent_series, rated_viewings = _viewing_history(db, user.id)
    blocked = set(
        db.scalars(select(MovieBlock.movie_id).where(MovieBlock.user_id == user.id)).all()
    )
    movie_by_id = {m.tmdb_id: m for _, m in rows}
    candidates: list[engine.Candidate] = [
        engine.Candidate(
            tmdb_id=m.tmdb_id,
            added_at=e.added_at,
            release_date=m.release_date,
            runtime_minutes=m.runtime_minutes,
            genre_ids=tuple(m.genre_ids),
            adult=m.adult,
            metadata_ready=m.metadata_status == "ready",
            vote_average=m.vote_average,
            vote_count=m.vote_count,
            last_offered_at=last_offer.get(m.tmdb_id),
            offered_this_session=m.tmdb_id in tonight,
            watched=m.tmdb_id in watched,
            blocked=m.tmdb_id in blocked,
        )
        for e, m in rows
    ]
    series_meta: dict[int, tuple[Series, series_episodes.Ep | None]] = {}
    if want_shows:
        series_cands, series_meta = _series_candidates(db, user, s, local)
        candidates.extend(series_cands)
    hidden = 0
    if series_enabled():
        hidden = (0 if want_movies else _active_count(db, user.id)) + (
            0 if want_shows else _active_series_count(db, user.id)
        )
    ctx = engine.EffectiveContext(
        desired_experience=eff["desired_experience"],
        max_runtime_minutes=eff.get("max_runtime_minutes"),
        pace=eff.get("pace"),
        complexity_max=_dec(eff.get("complexity_max")),
        heaviness_max=_dec(eff.get("heaviness_max")),
        prefer_genre_ids=frozenset(eff.get("prefer_genre_ids", [])),
        avoid_genre_ids=frozenset(eff.get("avoid_genre_ids", [])),
    )
    preferences = {
        int(g): Decimal(str(v)) for g, v in prefs.genre_preferences.items() if str(g).isdigit()
    }
    result = engine.rank(
        engine.RankingInput(
            candidates=tuple(candidates),
            context=ctx,
            local_date=local,
            evaluation_time=now,
            genre_preferences=preferences,
            rated_viewings=rated_viewings,
            recent_genre_sets=recent,
            recent_series_ids=recent_series,
        ),
        CONFIG,
    )
    context_snapshot = {
        "requested": s.context,
        "effective": eff,
        "media": media,
        "evaluation_time": now.isoformat(),
        "local_date": local.isoformat(),
        "genre_affinities": {str(g): f"{a:.6f}" for g, a in result.affinities.items()},
        "affinity_support": {str(g): f"{a:.6f}" for g, a in result.affinity_support.items()},
        "recent_genre_sets": [list(g) for g in recent],
    }
    exclusion_summary = {
        "candidate_count": result.candidate_count,
        "eligible_count": len(result.ranked),
        "primary_exclusion_counts": result.primary_exclusions,
        "hidden_by_preference": hidden,
    }
    rec = Recommendation(
        id=uuid.uuid4(),
        session_id=s.id,
        engine_version=CONFIG.engine_version,
        config_version=CONFIG.version,
        config_hash=CONFIG.hash,
        config_snapshot=json.loads(engine.canonical_json(CONFIG.snapshot)),
        context_snapshot=context_snapshot,
        exclusion_summary=exclusion_summary,
        created_at=now,
    )
    winner = result.winner
    if winner is None:
        rec.status = "no_match"
        rec.resolved_at = now
        rec.top_candidates = []
        rec.reason_data = {"reasons": [], "uncertainties": []}
        rec.explanation = explain.no_match_text(
            result.candidate_count, result.primary_exclusions, media
        )
        rec.no_match_summary = {
            "candidate_count": result.candidate_count,
            "primary_exclusion_counts": result.primary_exclusions,
            "hidden_by_preference": hidden,
            "suggested_actions": explain.suggested_actions(result.primary_exclusions, media),
        }
    else:

        def display(c: engine.Candidate, continues: bool = False) -> dict[str, Any]:
            if c.kind == "series":
                series, ep = series_meta[c.tmdb_id]
                if ep is None:  # pragma: no cover (eligible series have an episode)
                    raise AppError(500, "INTERNAL_ERROR", "Couldn't record this pick.")
                return series_display.episode_card(
                    series, ep, names, image_base, continues=continues
                )
            return movies.summary(movie_by_id[c.tmdb_id], names, image_base, local).model_dump(
                mode="json"
            )

        def compact(c: engine.Candidate) -> dict[str, Any]:
            if c.kind == "series":
                series, _ = series_meta[c.tmdb_id]
                return {
                    "series_id": c.tmdb_id,
                    "title": series.name,
                    "season_number": c.season_number,
                    "episode_number": c.episode_number,
                }
            return {"tmdb_id": c.tmdb_id, "title": movie_by_id[c.tmdb_id].title}

        wc = winner.candidate
        reasons = [explain.reason_out(r, names) for r in winner.reasons]
        uncertain = [explain.reason_out(r, names) for r in winner.uncertainties]
        rec.status = "offered"
        rec.total_score = winner.total.quantize(Decimal("0.000001"))
        if wc.kind == "series":
            rec.media_kind = "episode"
            rec.series_id = wc.tmdb_id
            rec.season_number = wc.season_number
            rec.episode_number = wc.episode_number
        else:
            rec.movie_id = wc.tmdb_id
        rec.winner_snapshot = _scored_record(
            winner, display(wc, continues=winner.contributions.get("S", Decimal(0)) > 0)
        )
        rec.reason_data = {"reasons": reasons, "uncertainties": uncertain}
        rec.explanation = " ".join(r["text"] for r in reasons + uncertain)
        runners = [_scored_record(r, compact(r.candidate)) for r in result.ranked[1:10]]
        mandatory = len(
            engine.canonical_json([rec.winner_snapshot, context_snapshot, rec.config_snapshot])
        )
        if mandatory > EVIDENCE_LIMIT_BYTES:
            raise AppError(500, "EVIDENCE_TOO_LARGE", "Couldn't record this pick.")
        while runners and mandatory + len(engine.canonical_json(runners)) > EVIDENCE_LIMIT_BYTES:
            runners.pop()
            rec.comparisons_truncated = True
        rec.top_candidates = runners
    db.add(rec)
    db.flush()
    s.current_recommendation_id = rec.id
    return rec


# --- commands -------------------------------------------------------------------------


def _version_conflict(current: int) -> AppError:
    return AppError(
        409,
        "VERSION_CONFLICT",
        "Tonight's plan changed. Refresh and try again.",
        details={"current_version": current},
    )


def _check_version(s: RecommendationSession | None, expected: int) -> None:
    current = s.version if s is not None else 0
    if expected != current:
        raise _version_conflict(current)


def _not_completed(s: RecommendationSession | None) -> None:
    if s is not None and s.completed_at is not None:
        raise AppError(409, "TODAY_COMPLETED", "Tonight is already done.")


def _context_dict(ctx: SessionContext) -> dict[str, Any]:
    return ctx.model_dump(mode="json")


def _apply_context(
    db: Session,
    user: User,
    s: RecommendationSession | None,
    ctx: dict[str, Any],
    local: date,
    now: datetime,
) -> tuple[RecommendationSession, bool]:
    """Creates the session or replaces its context. A changed scoring context
    supersedes the current pick; a mood-only edit keeps it. Returns
    (session, version already bumped)."""
    if s is None:
        s = RecommendationSession(
            id=uuid.uuid4(),
            user_id=user.id,
            local_date=local,
            timezone_snapshot=user.timezone,
            day_ends_at=_day_end(local, user.timezone),
            context=ctx,
            version=1,
            created_at=now,
            updated_at=now,
        )
        db.add(s)
        db.flush()
        return s, True
    if ctx == s.context:
        return s, False
    prefs = _prefs(db, user.id)
    changed = scoring_key(effective_context(ctx, prefs)[0]) != scoring_key(
        effective_context(s.context, prefs)[0]
    )
    s.context = ctx
    if changed:
        _clear_pick(db, s, now)
    _bump(s, now)
    return s, True


def _last_attempt(db: Session, s: RecommendationSession) -> Recommendation | None:
    return db.scalar(
        select(Recommendation)
        .where(Recommendation.session_id == s.id)
        .order_by(Recommendation.created_at.desc(), Recommendation.id.desc())
        .limit(1)
    )


def _mutation(
    db: Session,
    user_id: uuid.UUID,
    key: uuid.UUID,
    operation: str,
    body: dict[str, Any],
    run: Callable[[User, datetime], tuple[int, dict[str, Any]]],
) -> tuple[int, dict[str, Any]]:
    """Shared frame: lock user, replay or run, store the response, commit."""
    digest = idempotency.request_hash(body)
    with db.begin():
        user = lock_user(db, user_id)
        replay = idempotency.lookup(db, user_id, key, operation, digest)
        if replay is not None:
            return replay.status, replay.body
        status, payload = run(user, utc_now())
        db.flush()
        idempotency.store(db, user_id, key, operation, digest, status, payload)
    return status, payload


def choose(
    db: Session,
    user_id: uuid.UUID,
    req: ChooseRequest,
    key: uuid.UUID,
    names: dict[int, str],
    image_base: str,
) -> tuple[int, dict[str, Any]]:
    def run(user: User, now: datetime) -> tuple[int, dict[str, Any]]:
        local = local_date_for(user, now)
        s = _today_session(db, user.id, local)
        _check_version(s, req.expected_session_version)
        _not_completed(s)
        if req.context is not None:
            s, bumped = _apply_context(db, user, s, _context_dict(req.context), local, now)
        elif s is None:
            raise AppError(422, "CONTEXT_REQUIRED", "Choose what you want from tonight first.")
        else:
            bumped = False
        current = _current(db, s)
        if current is not None and current.status in ("offered", "accepted"):
            return 200, envelope(db, user, now)  # same film; reload never re-picks
        rejections, attempts = _counts(db, s)
        if rejections >= PAUSE_AFTER_REJECTIONS and not req.continue_after_pause:
            last = _last_attempt(db, s)
            eff = effective_context(s.context, _prefs(db, user.id))[0]
            if last is not None and scoring_key(last.context_snapshot["effective"]) == scoring_key(
                eff
            ):
                raise AppError(
                    409,
                    "CONTEXT_REVIEW_REQUIRED",
                    "You've passed on a few tonight. Adjust tonight's context or continue once.",
                )
        if attempts >= DAILY_ATTEMPT_LIMIT:
            raise AppError(429, "DAILY_ATTEMPT_LIMIT", "That's enough picks for today.")
        select_one(db, user, s, now, names, image_base)
        if not bumped:
            _bump(s, now)
        return 201, envelope(db, user, now)

    body = req.model_dump(mode="json")
    return _mutation(db, user_id, key, "POST /api/v1/today/choose", body, run)


def patch_context(
    db: Session, user_id: uuid.UUID, req: ContextPatch, key: uuid.UUID
) -> tuple[int, dict[str, Any]]:
    def run(user: User, now: datetime) -> tuple[int, dict[str, Any]]:
        local = local_date_for(user, now)
        s = _today_session(db, user.id, local)
        _check_version(s, req.expected_session_version)
        _not_completed(s)
        _apply_context(db, user, s, _context_dict(req.context), local, now)
        return 200, envelope(db, user, now)

    body = req.model_dump(mode="json")
    return _mutation(db, user_id, key, "PATCH /api/v1/today/context", body, run)


def _owned_today_pick(
    db: Session, user: User, rec_id: uuid.UUID, now: datetime, expected: int
) -> tuple[RecommendationSession, Recommendation]:
    """The caller's recommendation in today's session, current and open."""
    row = db.execute(
        select(Recommendation, RecommendationSession)
        .join(RecommendationSession, RecommendationSession.id == Recommendation.session_id)
        .where(Recommendation.id == rec_id, RecommendationSession.user_id == user.id)
    ).one_or_none()
    if row is None:
        raise AppError(404, "NOT_FOUND", "That recommendation was not found.")
    rec, s = row
    if s.local_date != local_date_for(user, now):
        raise AppError(409, "SESSION_EXPIRED", "That pick was for another day.")
    _check_version(s, expected)
    _not_completed(s)
    if s.current_recommendation_id != rec.id or rec.status not in ("offered", "accepted"):
        raise AppError(409, "INVALID_TRANSITION", "That pick is no longer current.")
    return s, rec


def accept(
    db: Session, user_id: uuid.UUID, rec_id: uuid.UUID, expected: int, key: uuid.UUID
) -> tuple[int, dict[str, Any]]:
    """Watch Tonight: intent only. No viewing, rating or watchlist change."""

    def run(user: User, now: datetime) -> tuple[int, dict[str, Any]]:
        s, rec = _owned_today_pick(db, user, rec_id, now, expected)
        if rec.status == "offered":
            rec.status = "accepted"
            rec.accepted_at = now
            _bump(s, now)
        return 200, envelope(db, user, now)

    body = {"expected_session_version": expected}
    return _mutation(db, user_id, key, f"POST /api/v1/recommendations/{rec_id}/accept", body, run)


def follow_up_action(
    db: Session,
    user_id: uuid.UUID,
    rec_id: uuid.UUID,
    action: str,
    key: uuid.UUID,
) -> tuple[int, dict[str, Any]]:
    """Resolve or defer the most recent accepted pick using the caller's date."""
    operation = f"POST /api/v1/recommendations/{rec_id}/follow-up"

    def run(user: User, now: datetime) -> tuple[int, dict[str, Any]]:
        local = local_date_for(user, now)
        row = db.execute(
            select(Recommendation, RecommendationSession)
            .join(RecommendationSession, RecommendationSession.id == Recommendation.session_id)
            .where(Recommendation.id == rec_id, RecommendationSession.user_id == user.id)
            .with_for_update(of=Recommendation)
        ).first()
        if row is None:
            raise AppError(404, "NOT_FOUND", "That recommendation was not found.")
        rec, session = row
        if rec.status != "accepted" or rec.follow_up_resolved or session.local_date >= local:
            raise AppError(409, "INVALID_TRANSITION", "That follow-up is no longer available.")
        if action == "not_yet":
            rec.follow_up_prompted_on = local
        elif action == "no":
            rec.follow_up_resolved = True
        elif action == "yes" and rec.media_kind == "episode":
            _watch_episode(db, user, rec, now, source="follow_up", rating=None)
            rec.status = "watched"
            rec.resolved_at = now
            rec.follow_up_resolved = True
            session.completed_at = now
        elif action == "yes":
            movie = db.get(Movie, rec.movie_id)
            if movie is None:
                raise AppError(404, "NOT_FOUND", "That film was not found.")
            record_viewing(
                db, user, movie, now, now, source="recommendation", recommendation_id=rec.id
            )
            rec.status = "watched"
            rec.resolved_at = now
            rec.follow_up_resolved = True
            session.completed_at = now
            on_watchlist_removed(db, user, movie.tmdb_id, now)
        else:
            raise AppError(422, "VALIDATION_ERROR", "Choose yes, no or not yet.")
        return 200, envelope(db, user, now)

    return _mutation(db, user_id, key, operation, {"action": action}, run)


def mark_watched(
    db: Session,
    user_id: uuid.UUID,
    rec_id: uuid.UUID,
    expected: int,
    rating: int | None,
    key: uuid.UUID,
    names: dict[int, str],
    image_base: str,
) -> tuple[int, dict[str, Any]]:
    operation = f"POST /api/v1/recommendations/{rec_id}/watched"

    def run(user: User, now: datetime) -> tuple[int, dict[str, Any]]:
        session, rec = _owned_today_pick(db, user, rec_id, now, expected)
        if rec.media_kind == "episode":
            ev = _watch_episode(db, user, rec, now, source="recommendation", rating=rating)
            rec.status = "watched"
            rec.resolved_at = now
            rec.follow_up_resolved = True
            session.completed_at = now
            _bump(session, now)
            assert rec.winner_snapshot is not None  # noqa: S101 (selected rows have one)
            return 200, {
                "viewing": _episode_viewing_out(db, ev, rec.winner_snapshot),
                "today": envelope(db, user, now),
            }
        movie = db.get(Movie, rec.movie_id)
        if movie is None:
            raise AppError(404, "NOT_FOUND", "That film was not found.")
        viewing = record_viewing(
            db,
            user,
            movie,
            now,
            now,
            source="recommendation",
            rating=rating,
            recommendation_id=rec.id,
        )
        rec.status = "watched"
        rec.resolved_at = now
        rec.follow_up_resolved = True
        session.completed_at = now
        _bump(session, now)
        return 200, {
            "viewing": viewing_summary(viewing, movie, names, image_base),
            "today": envelope(db, user, now),
        }

    body = {"expected_session_version": expected, "rating": rating}
    return _mutation(db, user_id, key, operation, body, run)


def _watch_episode(
    db: Session,
    user: User,
    rec: Recommendation,
    now: datetime,
    *,
    source: str,
    rating: int | None,
) -> EpisodeViewing:
    """Confirms the recommended episode as watched and advances the show's
    progress in the same transaction. A pick whose episode is no longer the
    show's next one is stale (progress moved on another device or by hand):
    nothing is recorded and Today reloads."""
    if rec.series_id is None or rec.season_number is None or rec.episode_number is None:
        raise AppError(500, "INTERNAL_ERROR", "Couldn't record this episode.")
    entry = db.scalar(
        select(SeriesEntry)
        .where(
            SeriesEntry.user_id == user.id,
            SeriesEntry.series_id == rec.series_id,
            SeriesEntry.status == "active",
        )
        .with_for_update()
    )
    series = db.get(Series, rec.series_id)
    if entry is None or series is None:
        raise AppError(409, "INVALID_TRANSITION", "That show is no longer on your watchlist.")
    key = (rec.season_number, rec.episode_number)
    existing = db.scalar(
        select(EpisodeViewing).where(
            EpisodeViewing.user_id == user.id,
            EpisodeViewing.series_id == rec.series_id,
            EpisodeViewing.season_number == key[0],
            EpisodeViewing.episode_number == key[1],
        )
    )
    nxt = series_history.first_after(db, rec.series_id, series_history.progress_of(entry))
    if existing is None and (nxt is None or nxt.key != key):
        raise AppError(409, "INVALID_TRANSITION", "Your progress changed. Tonight was refreshed.")
    episode = nxt if nxt is not None and nxt.key == key else series_episodes.Ep(*key)
    viewing, _ = series_history.record_episode_viewing(
        db,
        user.id,
        entry,
        series,
        episode,
        now,
        source=source,
        rating=rating,
        recommendation_id=rec.id,
    )
    return viewing


def _reject_effect(
    req: RejectRequest, ctx: dict[str, Any], eff: dict[str, Any], movie_genres: list[int]
) -> dict[str, Any]:
    """Validates reason details and returns tonight's new context."""
    allowed = {
        "too_long": {"max_runtime_minutes"},
        "wrong_genre": {"avoid_genre_ids"},
        "already_watched": {"watched_at"},
    }
    extra = set(req.details) - allowed.get(req.reason, set())
    if extra:
        raise AppError(
            422,
            "VALIDATION_ERROR",
            "Unsupported detail for this reason.",
            details={"fields": sorted(f"details.{k}" for k in extra)},
        )
    new = dict(ctx)
    if req.reason == "too_long" and "max_runtime_minutes" in req.details:
        cap = req.details["max_runtime_minutes"]
        current_cap = eff.get("max_runtime_minutes")
        if (
            not isinstance(cap, int)
            or isinstance(cap, bool)
            or not 1 <= cap <= 600
            or (current_cap is not None and cap >= current_cap)
        ):
            raise AppError(
                422,
                "VALIDATION_ERROR",
                "Choose a shorter time limit.",
                details={"fields": ["details.max_runtime_minutes"]},
            )
        new["max_runtime_minutes"] = cap
    if req.reason == "wrong_genre":
        ids = req.details.get("avoid_genre_ids")
        if (
            not isinstance(ids, list)
            or not ids
            or len(set(ids)) != len(ids)
            or not set(ids) <= set(movie_genres)
        ):
            raise AppError(
                422,
                "VALIDATION_ERROR",
                "Choose at least one of this film's genres to avoid.",
                details={"fields": ["details.avoid_genre_ids"]},
            )
        new["avoid_genre_ids"] = sorted(set(ctx.get("avoid_genre_ids", [])) | set(ids))
        new["prefer_genre_ids"] = [g for g in ctx.get("prefer_genre_ids", []) if g not in ids]
    if req.reason == "too_serious":
        new["heaviness_max"] = LIGHTER_HEAVINESS
    if req.reason == "want_lighter":
        new["desired_experience"] = "relax"
        new["heaviness_max"] = LIGHTER_HEAVINESS
    return new


def _watched_at(raw: Any, now: datetime) -> datetime | None:
    """Optional known date; null means unknown. Never in the future."""
    if raw is None:
        return None
    try:
        value = datetime.fromisoformat(str(raw))
    except ValueError as e:
        raise AppError(
            422,
            "VALIDATION_ERROR",
            "watched_at must be a past date and time.",
            details={"fields": ["details.watched_at"]},
        ) from e
    if value.tzinfo is None or value > now:
        raise AppError(
            422,
            "VALIDATION_ERROR",
            "watched_at must be a past date and time.",
            details={"fields": ["details.watched_at"]},
        )
    return value


def reject(
    db: Session,
    user_id: uuid.UUID,
    rec_id: uuid.UUID,
    req: RejectRequest,
    key: uuid.UUID,
    names: dict[int, str],
    image_base: str,
) -> tuple[int, dict[str, Any]]:
    """Temporary rejection: never a dislike. Feedback, context effect, pointer
    clear and at most ONE replacement commit together, version bumped once."""

    def run(user: User, now: datetime) -> tuple[int, dict[str, Any]]:
        s, rec = _owned_today_pick(db, user, rec_id, now, req.expected_session_version)
        prefs = _prefs(db, user.id)
        eff, _ = effective_context(s.context, prefs)
        snapshot = rec.winner_snapshot or {}
        if rec.media_kind == "episode":
            genres = snapshot.get("episode", {}).get("series", {}).get("genre_ids", [])
            if req.reason == "already_watched":
                raise AppError(
                    422,
                    "VALIDATION_ERROR",
                    "To say you've seen this episode, set your progress for the show.",
                    details={"fields": ["reason"]},
                )
        else:
            genres = snapshot.get("movie", {}).get("genre_ids", [])
        s.context = _reject_effect(req, s.context, eff, genres)
        viewing = watched_movie = None
        if req.reason == "already_watched":
            watched_movie = db.get(Movie, rec.movie_id)
            if watched_movie is None:  # pragma: no cover (FK)
                raise AppError(404, "NOT_FOUND", "That film was not found.")
            viewing = record_viewing(
                db, user, watched_movie, _watched_at(req.details.get("watched_at"), now), now
            )
        if req.reason == "never_recommend" and rec.media_kind == "episode":
            if rec.series_id is not None and db.get(SeriesBlock, (user.id, rec.series_id)) is None:
                db.add(SeriesBlock(user_id=user.id, series_id=rec.series_id))
        elif req.reason == "never_recommend":
            blocked_movie = db.get(Movie, rec.movie_id)
            if blocked_movie is None:
                raise AppError(404, "NOT_FOUND", "That film was not found.")
            if db.get(MovieBlock, (user.id, blocked_movie.tmdb_id)) is None:
                db.add(MovieBlock(user_id=user.id, movie_id=blocked_movie.tmdb_id))
            entry = db.scalar(
                select(WatchlistEntry).where(
                    WatchlistEntry.user_id == user.id,
                    WatchlistEntry.movie_id == blocked_movie.tmdb_id,
                    WatchlistEntry.status == "active",
                )
            )
            if entry is not None:
                entry.status = "removed"
                entry.removed_at = now
                entry.updated_at = now
        rec.status = "rejected"
        rec.resolved_at = now
        feedback = RejectionFeedback(
            id=uuid.uuid4(),
            recommendation_id=rec.id,
            reason=req.reason,
            details=req.details,
            note=req.note,
            created_at=now,
        )
        db.add(feedback)
        s.current_recommendation_id = None
        _bump(s, now)
        db.flush()
        outcome = "not_requested"
        if req.choose_another:
            rejections, attempts = _counts(db, s)
            if rejections >= PAUSE_AFTER_REJECTIONS:
                outcome = "paused"
            elif attempts >= DAILY_ATTEMPT_LIMIT:
                outcome = "daily_limit"
            else:
                picked = select_one(db, user, s, now, names, image_base)
                outcome = "selected" if picked.status == "offered" else "no_match"
        return 200, {
            "feedback": {
                "id": str(feedback.id),
                "reason": feedback.reason,
                "created_at": _iso(now),
            },
            "viewing": viewing_summary(viewing, watched_movie, names, image_base)
            if viewing is not None and watched_movie is not None
            else None,
            "today": envelope(db, user, now),
            "replacement_outcome": outcome,
        }

    body = req.model_dump(mode="json")
    return _mutation(db, user_id, key, f"POST /api/v1/recommendations/{rec_id}/reject", body, run)


# --- invalidation from other features (called inside their transaction) --------------


def on_preferences_changed(db: Session, user: User, now: datetime) -> None:
    """Recommendation-affecting preference edits clear today's open pick (or
    cached no-match). A completed session keeps its card."""
    s = _today_session(db, user.id, local_date_for(user, now))
    if s is not None and s.completed_at is None and _clear_pick(db, s, now):
        _bump(s, now)


def on_watchlist_removed(db: Session, user: User, movie_id: int, now: datetime) -> None:
    s = _today_session(db, user.id, local_date_for(user, now))
    if s is None or s.completed_at is not None:
        return
    current = _current(db, s)
    if current is not None and current.status == "no_match":
        changed = _clear_pick(db, s, now)  # inventory changed: no-match is stale
    else:
        changed = _clear_pick(db, s, now, movie_id=movie_id)
    if changed:
        _bump(s, now)


def on_watchlist_added(db: Session, user: User, now: datetime) -> None:
    """Adding keeps an offered/accepted pick; only a cached no-match clears."""
    s = _today_session(db, user.id, local_date_for(user, now))
    if s is None or s.completed_at is not None:
        return
    current = _current(db, s)
    if current is not None and current.status == "no_match":
        s.current_recommendation_id = None
        _bump(s, now)


def on_movie_blocked(db: Session, user: User, movie_id: int, now: datetime) -> None:
    s = _today_session(db, user.id, local_date_for(user, now))
    if s is None or s.completed_at is not None:
        return
    if _clear_pick(db, s, now, movie_id=movie_id):
        _bump(s, now)


def on_series_removed(db: Session, user: User, series_id: int, now: datetime) -> None:
    """Removing a show clears its pick (or a stale no-match); no replacement."""
    s = _today_session(db, user.id, local_date_for(user, now))
    if s is None or s.completed_at is not None:
        return
    current = _current(db, s)
    if current is not None and current.status == "no_match":
        changed = _clear_pick(db, s, now)
    else:
        changed = _clear_pick(db, s, now, series_id=series_id)
    if changed:
        _bump(s, now)


def on_series_progress_changed(db: Session, user: User, series_id: int, now: datetime) -> None:
    """Progress moved (manual correction or a recorded watch): a pick for that
    show is stale and is superseded without choosing a replacement; a cached
    no-match goes too, since eligibility may have changed."""
    on_series_removed(db, user, series_id, now)


def on_series_blocked(db: Session, user: User, series_id: int, now: datetime) -> None:
    s = _today_session(db, user.id, local_date_for(user, now))
    if s is None or s.completed_at is not None:
        return
    if _clear_pick(db, s, now, series_id=series_id):
        _bump(s, now)


def on_series_unblocked(db: Session, user: User, series_id: int, now: datetime) -> None:
    on_movie_unblocked(db, user, series_id, now)


def on_movie_unblocked(db: Session, user: User, movie_id: int, now: datetime) -> None:
    s = _today_session(db, user.id, local_date_for(user, now))
    if s is None or s.completed_at is not None:
        return
    current = _current(db, s)
    if current is not None and current.status == "no_match":
        _clear_pick(db, s, now)
        _bump(s, now)


# --- history reads --------------------------------------------------------------------


def _encode_cursor(created_at: datetime, rec_id: uuid.UUID) -> str:
    raw = f"{created_at.isoformat()}|{rec_id}".encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _decode_cursor(cursor: str) -> tuple[datetime, uuid.UUID]:
    try:
        raw = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)).decode()
        stamp, rec_id = raw.split("|", 1)
        return datetime.fromisoformat(stamp), uuid.UUID(rec_id)
    except (ValueError, binascii.Error, UnicodeDecodeError) as e:
        raise AppError(
            422, "VALIDATION_ERROR", "Invalid cursor.", details={"fields": ["cursor"]}
        ) from e


def history(
    db: Session, user_id: uuid.UUID, limit: int, cursor: str | None, status: str | None
) -> dict[str, Any]:
    stmt = (
        select(Recommendation, RecommendationSession)
        .join(RecommendationSession, RecommendationSession.id == Recommendation.session_id)
        .where(RecommendationSession.user_id == user_id)
        .order_by(Recommendation.created_at.desc(), Recommendation.id.desc())
        .limit(limit + 1)
    )
    if status:
        stmt = stmt.where(Recommendation.status == status)
    if cursor:
        created, rec_id = _decode_cursor(cursor)
        stmt = stmt.where(
            tuple_(Recommendation.created_at, Recommendation.id) < tuple_(created, rec_id)
        )
    rows = db.execute(stmt).all()
    page = rows[:limit]
    return {
        "items": [
            summary(r)
            | {
                "local_date": s.local_date.isoformat(),
                "timezone": s.timezone_snapshot,
                "desired_experience": s.context["desired_experience"],
            }
            for r, s in page
        ],
        "next_cursor": _encode_cursor(page[-1][0].created_at, page[-1][0].id)
        if len(rows) > limit
        else None,
    }


def _owned(db: Session, user_id: uuid.UUID, rec_id: uuid.UUID) -> Recommendation:
    rec = db.scalar(
        select(Recommendation)
        .join(RecommendationSession, RecommendationSession.id == Recommendation.session_id)
        .where(Recommendation.id == rec_id, RecommendationSession.user_id == user_id)
    )
    if rec is None:
        raise AppError(404, "NOT_FOUND", "That recommendation was not found.")
    return rec


def detail(db: Session, user_id: uuid.UUID, rec_id: uuid.UUID) -> dict[str, Any]:
    rec = _owned(db, user_id, rec_id)
    feedback = db.scalar(
        select(RejectionFeedback).where(RejectionFeedback.recommendation_id == rec.id)
    )
    breakdown = None
    if rec.winner_snapshot is not None:
        breakdown = {
            "components": {k: float(v) for k, v in rec.winner_snapshot["components"].items()},
            "weights": {k: float(v) for k, v in rec.config_snapshot["weights"].items()}
            | (
                {"S": float(rec.config_snapshot["continuity"]["max_bonus"])}
                if "S" in rec.winner_snapshot["components"]
                else {}
            ),
            "contributions": {k: float(v) for k, v in rec.winner_snapshot["contributions"].items()},
        }
    return {
        "recommendation": summary(rec),
        "context": rec.context_snapshot["requested"],
        "effective_context": rec.context_snapshot["effective"],
        "feedback": None
        if feedback is None
        else {
            "reason": feedback.reason,
            "details": feedback.details,
            "note": feedback.note,
            "created_at": _iso(feedback.created_at),
        },
        "breakdown": breakdown,
        "config_version": rec.config_version,
    }


def comparison(db: Session, user_id: uuid.UUID, rec_id: uuid.UUID) -> dict[str, Any]:
    rec = _owned(db, user_id, rec_id)
    return {
        "engine_version": rec.engine_version,
        "config_version": rec.config_version,
        "config_hash": rec.config_hash,
        "evaluated_at": rec.context_snapshot["evaluation_time"],
        "winner": rec.winner_snapshot,
        "top_candidates": rec.top_candidates,
        "exclusion_summary": rec.exclusion_summary,
        "comparisons_truncated": rec.comparisons_truncated,
    }
