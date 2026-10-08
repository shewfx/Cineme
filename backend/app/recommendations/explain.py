"""Deterministic reason templates (RECOMMENDATION_ENGINE "Reasons and
explanations"). Text is rendered once at selection and stored with the run,
so old cards keep their original wording. No generated prose."""

from typing import Any

from app.core.features import series_enabled

from .engine import Reason

INTENT_LABELS = {
    "make_me_laugh": "Make me laugh",
    "comfort": "Something comforting",
    "feel_it": "Let me feel it",
    "relax": "Something relaxing",
    "deep": "Something deep",
    "exciting": "Something exciting",
    "keep_me_hooked": "Keep me hooked",
    "surprise": "Surprise me",
}

EXCLUSION_LABELS = {
    "movie_unavailable": "not released yet or unavailable",
    "series_unavailable": "shows whose episodes couldn't be loaded",
    "series_completed": "shows you've finished",
    "series_caught_up": "shows you're caught up on",
    "next_episode_not_aired": "shows whose next episode hasn't aired yet",
    "already_watched": "already watched",
    "movie_blocked": "set to never recommend",
    "series_blocked": "shows set to never recommend",
    "offered_this_session": "already suggested tonight",
    "genre_blocked": "in a genre you're avoiding",
    "runtime_unknown": "runtime unknown with a time limit set",
    "runtime_exceeded": "longer than your time limit",
}


def _genres(ids: list[int], names: dict[int, str]) -> str | None:
    known = [names[i] for i in ids if i in names]
    return ", ".join(known) if known else None


def reason_text(reason: Reason, names: dict[int, str]) -> str:
    v: dict[str, Any] = reason.values
    match reason.code:
        case "fits_runtime":
            return f"{v['runtime_minutes']} minutes, within your {v['cap_minutes']}-minute limit."
        case "explicit_genre_match":
            g = _genres(v["genre_ids"], names)
            return f"Matches a genre you prefer ({g})." if g else "Matches a genre you prefer."
        case "learned_genre_match":
            g = _genres(v["genre_ids"], names)
            return f"You've rated {g} films well." if g else "You've rated films like it well."
        case "context_genre_proxy":
            g = _genres(v["genre_ids"], names)
            label = INTENT_LABELS[v["desired_experience"]]
            what = f"Its genre ({g})" if g else "Its genre"
            return f"{what} fits your “{label}” choice."
        case "tonight_genre_match":
            g = _genres(v["genre_ids"], names)
            return f"Matches tonight's preferred genre ({g})." if g else "Matches tonight's genres."
        case "continues_series":
            return f"Continue the series you're watching — S{v['season']} E{v['episode']}."
        case "variety":
            return "A change from what you've watched recently."
        case "waiting_in_watchlist":
            days = v["age_days"]
            span = f"{days} days" if days < 60 else f"{days // 30} months"
            return f"In your watchlist for {span}."
        case "not_offered_before":
            return "Cinemé hasn't suggested it before."
        case "not_offered_recently":
            return f"Not suggested in the last {v['days']} days."
        case "tmdb_rating":
            return f"Rated {v['vote_average']}/10 by {v['vote_count']:,} TMDB users."
        case "best_remaining_match":
            return "The best remaining match under tonight's choices."
        case "unknown_trait":
            return (
                f"Its {v['trait']} isn't known, so that part of tonight's request wasn't checked."
            )
        case "unknown_genres":
            return "Its genres aren't known, so your choice couldn't be matched."
    raise ValueError(f"no template for {reason.code}")


def reason_out(reason: Reason, names: dict[int, str]) -> dict[str, Any]:
    return {
        "code": reason.code,
        "values": reason.values,
        "source": reason.source,
        "text": reason_text(reason, names),
    }


def no_match_text(candidate_count: int, counts: dict[str, int], media: str = "movies") -> str:
    if candidate_count == 0:
        return "Your watchlist is empty."
    parts = [f"{n} {EXCLUSION_LABELS[code]}" for code, n in counts.items()]
    if media == "movies":
        noun = "film" if candidate_count == 1 else "films"
    else:
        noun = "title" if candidate_count == 1 else "titles"
    return (
        f"None of the {candidate_count} {noun} in your watchlist fit tonight: "
        + "; ".join(parts)
        + "."
    )


def suggested_actions(counts: dict[str, int], media: str = "movies") -> list[str]:
    actions = []
    if counts.keys() & {"runtime_unknown", "runtime_exceeded"}:
        actions.append("edit_runtime")
    if "genre_blocked" in counts:
        actions.append("edit_genres")
    if media in ("movies", "movies_and_shows"):
        actions.append("add_movies")
    if media in ("shows", "movies_and_shows"):
        actions.append("add_shows")
    if media != "movies_and_shows" and series_enabled():
        actions.append("change_media_preference")
    return actions
