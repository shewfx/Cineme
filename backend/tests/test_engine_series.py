"""`weighted_v2`: next-episode candidates and the series continuity bonus
(ADR 011, SERIES_DESIGN section 6). Pure: typed fixtures only."""

from dataclasses import replace
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal
from typing import Any

import pytest

from app.recommendations import engine
from app.recommendations.engine import (
    Candidate,
    EffectiveContext,
    EngineConfig,
    RankingInput,
    load_config,
    load_series_config,
    parse_config,
    rank,
)

V1 = load_config()
V2 = load_series_config()
NOW = datetime(2026, 10, 2, 20, 0, tzinfo=UTC)
TODAY = date(2026, 10, 2)
D = Decimal


def movie(tmdb_id: int, **kw: Any) -> Candidate:
    base: dict[str, Any] = {
        "tmdb_id": tmdb_id,
        "added_at": NOW - timedelta(days=10),
        "release_date": date(2000, 1, 1),
        "runtime_minutes": 100,
        "genre_ids": (18,),
    }
    return Candidate(**(base | kw))


def show(series_id: int, **kw: Any) -> Candidate:
    """A show's next episode (S1 E5 unless overridden), 45 minutes, aired."""
    base: dict[str, Any] = {
        "tmdb_id": series_id,
        "added_at": NOW - timedelta(days=10),
        "release_date": date(2015, 1, 1),
        "runtime_minutes": 45,
        "genre_ids": (18,),
        "kind": "series",
        "season_number": 1,
        "episode_number": 5,
        "episode_state": "up_next",
    }
    return Candidate(**(base | kw))


def ctx(**kw: Any) -> EffectiveContext:
    return EffectiveContext(**({"desired_experience": "surprise"} | kw))


def run(
    candidates: list[Candidate],
    cfg: EngineConfig = V2,
    context: EffectiveContext | None = None,
    **kw: Any,
) -> engine.RankingResult:
    return rank(
        RankingInput(
            candidates=tuple(candidates),
            context=context or ctx(),
            local_date=TODAY,
            evaluation_time=NOW,
            **kw,
        ),
        cfg,
    )


def bonus(c: Candidate) -> Decimal:
    result = run([c])
    return result.ranked[0].contributions.get("S", D(0))


def watched(days_ago: int, n: int) -> dict[str, Any]:
    return {
        "confirmed_watch_count": n,
        "last_confirmed_watch": TODAY - timedelta(days=days_ago),
    }


# --- configuration -------------------------------------------------------------------


def test_v2_config_extends_v1_without_changing_it() -> None:
    assert V1.engine_version == "weighted_v1" and V1.continuity is None
    assert V2.engine_version == "weighted_v2" and V2.version == "weights_v2"
    assert V2.weights == V1.weights
    assert V2.continuity == engine.Continuity(D(12), 21, 3)
    assert V1.hash != V2.hash


@pytest.mark.parametrize(
    "block",
    [
        {"max_bonus": 21, "window_days": 21, "ramp_watches": 3},
        {"max_bonus": -1, "window_days": 21, "ramp_watches": 3},
        {"max_bonus": 12, "window_days": 0, "ramp_watches": 3},
        {"max_bonus": 12, "window_days": 21, "ramp_watches": True},
        {"max_bonus": 12, "window_days": 21},
        "twelve",
    ],
)
def test_invalid_continuity_config_is_rejected(block: Any) -> None:
    raw = dict(V2.snapshot)
    raw["continuity"] = block
    with pytest.raises(ValueError):
        parse_config(raw)


# --- continuity formula ----------------------------------------------------------------


def test_no_confirmed_watch_means_no_bonus() -> None:
    assert bonus(show(1)) == 0


@pytest.mark.parametrize(
    ("days_ago", "n", "expected"),
    [
        (0, 3, D(12)),
        (1, 3, D(12) * D(20) / D(21)),  # 11.428571...
        (10, 1, D(12) * D(11) / D(21) / 2),  # 3.142857...
        (10, 2, D(12) * D(11) / D(21) * D("0.75")),
        (20, 3, D(12) * D(1) / D(21)),
        (21, 3, D(0)),  # a full idle window: gone
        (22, 3, D(0)),
        (0, 1, D(6)),
        (0, 2, D(9)),
        (0, 3, D(12)),
        (0, 10, D(12)),  # momentum saturates: no unbounded growth
        (0, 500, D(12)),
    ],
)
def test_bonus_formula_boundaries(days_ago: int, n: int, expected: Decimal) -> None:
    got = bonus(show(1, **watched(days_ago, n)))
    assert abs(got - expected) < D("0.000001")
    assert got <= V2.continuity.max_bonus  # type: ignore[union-attr]


def test_bonus_never_exceeds_the_maximum_and_adds_to_the_base_score() -> None:
    plain = run([show(1)]).ranked[0]
    boosted = run([show(1, **watched(0, 5))]).ranked[0]
    assert boosted.total == plain.total + 12
    assert plain.components["S"] == 0 and boosted.components["S"] == 1


def test_a_skip_yesterday_damps_the_bonus_through_the_existing_recency_component() -> None:
    fresh = show(1, **watched(1, 3))
    skipped = replace(fresh, last_offered_at=NOW - timedelta(days=1))
    # R = 1/14 after one full day, applied to the bonus as well as the base score.
    assert abs(bonus(skipped) - bonus(fresh) / 14) < D("0.000001")
    assert run([skipped]).ranked[0].components["R"] == D(1) / 14


def test_displaying_or_accepting_is_not_watching() -> None:
    # Offers change only last_offered_at; with no confirmed watch there is no bonus.
    offered_before = show(1, last_offered_at=NOW - timedelta(days=30))
    assert bonus(offered_before) == 0


def test_movies_never_receive_the_bonus() -> None:
    m = run([movie(1)]).ranked[0]
    assert "S" not in m.components and "S" not in m.contributions


# --- ranking with continuity ------------------------------------------------------------


def test_continuing_beats_an_equally_suitable_series() -> None:
    older = NOW - timedelta(days=50)  # the other show would win a plain tie-break
    result = run(
        [
            show(1, added_at=older),
            show(2, added_at=NOW - timedelta(days=10), **watched(1, 3)),
        ]
    )
    assert [r.candidate.tmdb_id for r in result.ranked] == [2, 1]
    assert result.ranked[0].reasons[0].code == "continues_series"
    assert result.ranked[0].reasons[0].values == {"season": 1, "episode": 5}


def test_idle_continuity_fades_to_a_plain_tie_break() -> None:
    older = NOW - timedelta(days=50)
    result = run([show(1, added_at=older), show(2, **watched(25, 3))])
    assert result.ranked[0].candidate.tmdb_id == 1
    assert result.ranked[1].contributions["S"] == 0


def test_a_materially_better_title_beats_a_fully_boosted_series() -> None:
    # A confirmed intent match is worth 18 points of C; the bonus caps at 12.
    exciting = ctx(desired_experience="exciting")
    boosted_miss = show(1, genre_ids=(18,), **watched(0, 3))
    plain_hit = show(2, genre_ids=(28,))
    ranked = run([boosted_miss, plain_hit], context=exciting).ranked
    assert ranked[0].candidate.tmdb_id == 2
    # A mere watchlist-age or recency edge (at most 10 points) does not.
    older = show(3, genre_ids=(18,), added_at=NOW - timedelta(days=200))
    ranked = run([boosted_miss, older]).ranked
    assert ranked[0].candidate.tmdb_id == 1


def test_a_better_movie_beats_a_boosted_series_and_a_worse_one_does_not() -> None:
    exciting = ctx(desired_experience="exciting")
    series = show(1, genre_ids=(18,), **watched(0, 3))
    good_movie = movie(2, genre_ids=(28,))
    assert run([series, good_movie], context=exciting).ranked[0].candidate.kind == "movie"
    same_movie = movie(3, genre_ids=(18,))
    ranked = run([series, same_movie]).ranked
    assert ranked[0].candidate.kind == "series"


def test_ties_prefer_the_movie_then_the_lower_id() -> None:
    result = run([show(5), movie(5), show(4)])
    assert [(r.candidate.kind, r.candidate.tmdb_id) for r in result.ranked] == [
        ("movie", 5),
        ("series", 4),
        ("series", 5),
    ]


def test_ranking_is_deterministic_and_input_order_free() -> None:
    items = [show(i, **watched(i % 5, 1 + i % 4)) for i in range(1, 9)] + [
        movie(i) for i in range(20, 26)
    ]
    first = run(items)
    second = run(list(reversed(items)))
    assert [r.candidate.tmdb_id for r in first.ranked] == [
        r.candidate.tmdb_id for r in second.ranked
    ]
    assert [r.total for r in first.ranked] == [r.total for r in second.ranked]


# --- exclusions come before ranking -----------------------------------------------------------


@pytest.mark.parametrize(
    ("state", "code"),
    [
        ("unavailable", "series_unavailable"),
        ("completed", "series_completed"),
        ("caught_up", "series_caught_up"),
        ("not_aired", "next_episode_not_aired"),
    ],
)
def test_shows_without_an_eligible_episode_are_excluded_with_a_reason(
    state: str, code: str
) -> None:
    result = run([show(1, episode_state=state, **watched(0, 3))])
    assert result.ranked == ()
    assert result.primary_exclusions == {code: 1}


def test_runtime_rules_apply_to_the_episode() -> None:
    cap = ctx(max_runtime_minutes=40)
    unknown = show(1, runtime_minutes=None)
    long = show(2, runtime_minutes=45)
    exact = show(3, runtime_minutes=40)
    result = run([unknown, long, exact], context=cap)
    assert [r.candidate.tmdb_id for r in result.ranked] == [3]
    assert result.primary_exclusions == {"runtime_unknown": 1, "runtime_exceeded": 1}
    # Without a cap an unknown runtime stays eligible.
    assert [r.candidate.tmdb_id for r in run([unknown]).ranked] == [1]


def test_blocked_or_offered_shows_are_excluded_even_with_continuity() -> None:
    result = run(
        [
            show(1, blocked=True, **watched(0, 3)),
            show(2, offered_this_session=True, **watched(0, 3)),
            show(3, genre_ids=(10765,)),
        ],
        context=ctx(avoid_genre_ids=frozenset({10765})),
    )
    assert result.ranked == ()
    assert result.primary_exclusions == {
        "series_blocked": 1,
        "offered_this_session": 1,
        "genre_blocked": 1,
    }


def test_primary_counts_sum_to_the_candidates() -> None:
    items = [
        show(1, episode_state="caught_up"),
        show(2, episode_state="completed"),
        show(3, blocked=True),
        movie(4, watched=True),
        movie(5, release_date=None),
    ]
    result = run(items)
    assert sum(result.primary_exclusions.values()) == result.candidate_count == 5


# --- diversity ignores the candidate's own series ------------------------------------------------


def test_diversity_ignores_recent_viewings_of_the_candidates_own_series() -> None:
    recent = ((18, 35),)  # last night's episode of show 1: Drama + Comedy
    same = show(1, genre_ids=(18, 35), **watched(1, 1))
    other = show(2, genre_ids=(18, 35))
    result = run([same, other], recent_genre_sets=recent, recent_series_ids=(1,))
    by_id = {r.candidate.tmdb_id: r for r in result.ranked}
    assert by_id[1].components["D"] == D("0.5"), "own series ignored: neutral, not zero"
    assert by_id[2].components["D"] == 0, "another show with identical genres is not varied"


@pytest.mark.parametrize(
    ("days_ago", "exempt"),
    [(0, True), (20, True), (21, False), (60, False)],
)
def test_the_own_series_exemption_ends_with_the_continuity_window(
    days_ago: int, exempt: bool
) -> None:
    """D ignores the show's own recent viewing only while the show still earns
    a continuity bonus (window_days = 21); afterwards the normal rule applies."""
    recent = ((18, 35),)
    c = show(1, genre_ids=(18, 35), **watched(days_ago, 1))
    result = run([c], recent_genre_sets=recent, recent_series_ids=(1,))
    r = result.ranked[0]
    assert r.components["D"] == (D("0.5") if exempt else 0)
    assert (r.contributions["S"] > 0) is exempt, "same boundary as the bonus"


def test_a_show_with_no_confirmed_watch_gets_the_normal_diversity_rule() -> None:
    result = run(
        [show(1, genre_ids=(18, 35))], recent_genre_sets=((18, 35),), recent_series_ids=(1,)
    )
    assert result.ranked[0].components["D"] == 0


def test_movie_scores_are_identical_under_v1_and_v2() -> None:
    items = [
        movie(
            i,
            genre_ids=(28, 18) if i % 2 else (35,),
            runtime_minutes=80 + i,
            added_at=NOW - timedelta(days=i * 7),
            vote_average=D("7.5"),
            vote_count=300 + i,
            last_offered_at=NOW - timedelta(days=i) if i % 3 == 0 else None,
        )
        for i in range(1, 15)
    ]
    kwargs = {"genre_preferences": {35: D("0.6")}, "recent_genre_sets": ((18,), (35, 18))}
    context = ctx(desired_experience="exciting", max_runtime_minutes=92)
    one = run(items, V1, context, **kwargs)
    two = run(items, V2, context, **kwargs)
    assert [r.candidate.tmdb_id for r in one.ranked] == [r.candidate.tmdb_id for r in two.ranked]
    assert [r.total for r in one.ranked] == [r.total for r in two.ranked]
    assert [r.components for r in one.ranked] == [r.components for r in two.ranked]
    assert [r.reasons for r in one.ranked] == [r.reasons for r in two.ranked]
    assert one.primary_exclusions == two.primary_exclusions


def test_the_design_example_orders_as_documented() -> None:
    """SERIES_DESIGN section 6: a watched-3-of-5 show with a never-offered next
    episode beats an identical idle show and a comparable film; a skip yesterday
    hands the night to the film."""
    base = {"genre_ids": (18,), "vote_average": D("8.0"), "vote_count": 500}
    a = show(1, **base, **watched(1, 3))
    b = show(2, **base)
    film = movie(3, genre_ids=(18,), vote_average=D("8.0"), vote_count=500)
    ranked = run([a, b, film]).ranked
    assert ranked[0].candidate.tmdb_id == 1
    assert ranked[0].total - ranked[1].total > D("11")  # the bonus, 11.43

    skipped = replace(a, last_offered_at=NOW - timedelta(days=1))
    after = run([skipped, b, film]).ranked
    assert after[0].candidate.kind == "movie"
