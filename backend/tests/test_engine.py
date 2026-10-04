"""Pure scorer tests (RECOMMENDATION_ENGINE "Required tests"). No database,
network or clock: every input is a typed fixture."""

import ast
import json
import random
import time
from dataclasses import replace
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal
from pathlib import Path
from typing import Any

import pytest

from app.recommendations import engine
from app.recommendations.engine import (
    Candidate,
    EffectiveContext,
    RankingInput,
    RatedViewing,
    load_config,
    parse_config,
    rank,
)

CFG = load_config()
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


def ctx(**kw: Any) -> EffectiveContext:
    return EffectiveContext(**({"desired_experience": "surprise"} | kw))


def run(candidates: list[Candidate], context: EffectiveContext | None = None, **kw: Any):
    return rank(
        RankingInput(
            candidates=tuple(candidates),
            context=context or ctx(),
            local_date=TODAY,
            evaluation_time=NOW,
            **kw,
        ),
        CFG,
    )


# --- worked examples (RECOMMENDATION_ENGINE) -----------------------------------------

LOLA = movie(
    104,
    runtime_minutes=81,
    genre_ids=(28, 18, 53),
    pace=D("0.90"),
    complexity=D("0.40"),
    added_at=NOW - timedelta(days=30),
    vote_average=D("8.0"),
    vote_count=200,
)
GRAND = movie(
    120467,
    runtime_minutes=100,
    genre_ids=(35, 18),
    pace=D("0.70"),
    complexity=D("0.55"),
    added_at=NOW - timedelta(days=90),
    last_offered_at=NOW - timedelta(days=7),
    vote_average=D("9.0"),
    vote_count=200,
)
ARRIVAL = movie(
    329865, runtime_minutes=116, genre_ids=(18, 878, 9648), added_at=NOW - timedelta(days=60)
)
EXAMPLE = {
    "genre_preferences": {28: D("0.4"), 18: D(0), 53: D("0.5"), 35: D("0.8")},
    "recent_genre_sets": ((35, 18),),
}


def six(x: Decimal) -> str:
    return str(x.quantize(D("0.000001")))


def test_worked_example_totals_components_and_exclusion() -> None:
    result = run(
        [ARRIVAL, GRAND, LOLA],
        ctx(
            desired_experience="exciting",
            max_runtime_minutes=100,
            pace="high",
            complexity_max=D("0.45"),
        ),
        **EXAMPLE,
    )
    lola, grand = result.ranked
    assert lola.candidate.tmdb_id == 104 and grand.candidate.tmdb_id == 120467
    assert six(lola.total) == "74.333333"
    assert six(grand.total) == "61.681818"
    assert {k: six(v) for k, v in lola.components.items()} == {
        "G": "0.650000",
        "C": "0.916667",
        "D": "0.750000",
        "A": "0.333333",
        "R": "1.000000",
        "Q": "0.650000",
    }
    assert six(grand.components["C"]) == "0.622727"
    assert grand.components["D"] == 0 and grand.components["R"] == D("0.5")
    assert result.primary_exclusions == {"runtime_exceeded": 1}
    assert lola.reasons[0].code == "fits_runtime"
    assert lola.reasons[0].values == {"runtime_minutes": 81, "cap_minutes": 100}


def test_context_changes_the_winner() -> None:
    result = run(
        [GRAND, LOLA], ctx(desired_experience="relax", complexity_max=D("0.45")), **EXAMPLE
    )
    assert [s.candidate.tmdb_id for s in result.ranked] == [120467, 104]
    totals = {s.candidate.tmdb_id: six(s.total) for s in result.ranked}
    assert totals == {120467: "67.272727", 104: "64.833333"}


def test_no_enrichment_baseline_admits_uncertainty() -> None:
    bare = [replace(m, pace=None, complexity=None) for m in (LOLA, GRAND)]
    result = run(
        bare,
        ctx(desired_experience="exciting", pace="high", complexity_max=D("0.45")),
        **EXAMPLE,
    )
    totals = {s.candidate.tmdb_id: six(s.total) for s in result.ranked}
    assert totals == {104: "64.833333", 120467: "55.000000"}
    assert {r.values["trait"] for r in result.ranked[0].uncertainties} == {"pace", "complexity"}


def test_rejection_example_cap_90_is_no_match_not_relaxed() -> None:
    lola = replace(LOLA, offered_this_session=True)
    result = run([lola, GRAND, ARRIVAL], ctx(desired_experience="exciting", max_runtime_minutes=90))
    assert result.winner is None
    assert result.primary_exclusions == {"offered_this_session": 1, "runtime_exceeded": 2}
    assert sum(result.primary_exclusions.values()) == result.candidate_count


# --- hard filters --------------------------------------------------------------------


@pytest.mark.parametrize(
    ("overrides", "code"),
    [
        ({"metadata_ready": False}, "movie_unavailable"),
        ({"adult": True}, "movie_unavailable"),
        ({"release_date": None}, "movie_unavailable"),
        ({"release_date": date(2026, 10, 3)}, "movie_unavailable"),
        ({"watched": True}, "already_watched"),
        ({"blocked": True}, "movie_blocked"),
        ({"offered_this_session": True}, "offered_this_session"),
        ({"genre_ids": (27, 18)}, "genre_blocked"),
        ({"runtime_minutes": None}, "runtime_unknown"),
        ({"runtime_minutes": 91}, "runtime_exceeded"),
    ],
)
def test_each_hard_filter(overrides: dict[str, Any], code: str) -> None:
    result = run(
        [movie(1, **overrides)], ctx(max_runtime_minutes=90, avoid_genre_ids=frozenset({27}))
    )
    assert result.winner is None
    assert result.primary_exclusions == {code: 1}


def test_release_day_and_cap_equality_are_eligible() -> None:
    result = run([movie(1, release_date=TODAY, runtime_minutes=90)], ctx(max_runtime_minutes=90))
    assert result.winner is not None


def test_unknown_runtime_is_eligible_without_a_cap() -> None:
    assert run([movie(1, runtime_minutes=None)]).winner is not None


def test_primary_exclusion_is_the_first_applicable_code() -> None:
    everything = movie(
        1,
        release_date=None,
        watched=True,
        blocked=True,
        offered_this_session=True,
        genre_ids=(27,),
        runtime_minutes=None,
    )
    result = run([everything], ctx(max_runtime_minutes=90, avoid_genre_ids=frozenset({27})))
    assert result.primary_exclusions == {"movie_unavailable": 1}
    assert engine.exclusions(
        everything, ctx(max_runtime_minutes=90, avoid_genre_ids=frozenset({27})), TODAY
    ) == [
        "movie_unavailable",
        "already_watched",
        "movie_blocked",
        "offered_this_session",
        "genre_blocked",
        "runtime_unknown",
    ]


def test_one_eligible_film_is_chosen_even_with_a_weak_score() -> None:
    weak = movie(
        1, genre_ids=(99,), added_at=NOW, last_offered_at=NOW, vote_average=D(0), vote_count=5000
    )
    result = run([weak, movie(2, adult=True)], ctx(desired_experience="make_me_laugh"))
    assert result.winner is not None and result.winner.candidate.tmdb_id == 1


def test_empty_candidate_set_is_no_match() -> None:
    result = run([])
    assert result.winner is None and result.candidate_count == 0 and result.primary_exclusions == {}


# --- components ------------------------------------------------------------------------


@pytest.mark.parametrize("intent", [i for i in engine.INTENTS if i != "surprise"])
def test_desired_experience_matrix(intent: str) -> None:
    matching = next(iter(sorted(CFG.intent_genre_map[intent])))
    hit = engine.context_dimensions(
        movie(1, genre_ids=(matching,)), ctx(desired_experience=intent), CFG
    )
    miss = engine.context_dimensions(movie(1, genre_ids=(99,)), ctx(desired_experience=intent), CFG)
    unknown = engine.context_dimensions(movie(1, genre_ids=()), ctx(desired_experience=intent), CFG)
    assert (hit["intent"], miss["intent"], unknown["intent"]) == (D("0.8"), D("0.2"), D("0.5"))


def test_surprise_omits_the_intent_dimension() -> None:
    assert engine.context_dimensions(movie(1), ctx(desired_experience="surprise"), CFG) == {}
    assert run([movie(1)]).ranked[0].components["C"] == D("0.5")


def test_mood_is_not_an_engine_input() -> None:
    # Emotion never reaches the scorer: the context has no mood field at all.
    assert "current_mood" not in EffectiveContext.__dataclass_fields__


@pytest.mark.parametrize(("pace", "target"), [("low", "0.15"), ("medium", "0.5"), ("high", "0.85")])
def test_pace_targets(pace: str, target: str) -> None:
    dims = engine.context_dimensions(movie(1, pace=D(target)), ctx(pace=pace), CFG)
    assert dims["pace"] == 1
    assert engine.context_dimensions(movie(1), ctx(pace=pace), CFG)["pace"] == D("0.5")


@pytest.mark.parametrize(
    ("m", "x", "expected"),
    [("0", "0", "1"), ("0", "0.5", "0.5"), ("0", "1", "0"), ("1", "1", "1"), ("0.45", "0.40", "1")],
)
def test_trait_maximum_boundaries(m: str, x: str, expected: str) -> None:
    dims = engine.context_dimensions(movie(1, heaviness=D(x)), ctx(heaviness_max=D(m)), CFG)
    assert dims["heaviness"] == D(expected)


def test_preferred_genres_dimension() -> None:
    prefer = ctx(prefer_genre_ids=frozenset({35}))
    assert (
        engine.context_dimensions(movie(1, genre_ids=(35, 18)), prefer, CFG)["prefer_genres"] == 1
    )
    assert engine.context_dimensions(movie(1, genre_ids=(18,)), prefer, CFG)["prefer_genres"] == 0
    assert engine.context_dimensions(movie(1, genre_ids=()), prefer, CFG)["prefer_genres"] == D(
        "0.5"
    )


def _affinity(prefs: dict[int, Decimal], viewings: tuple[RatedViewing, ...]) -> dict[int, Decimal]:
    inp = RankingInput((), ctx(), TODAY, NOW, genre_preferences=prefs, rated_viewings=viewings)
    return engine.genre_affinities(inp, CFG)[0]


def test_rating_shrinkage_multigenre_allocation_and_edit_replacement() -> None:
    loved = _affinity({35: D("0.6")}, (RatedViewing((35, 18), 5),))
    assert six(loved[35]) == "0.680000"  # (1.2 + 0.5) / 2.5
    disliked = _affinity({35: D("0.6")}, (RatedViewing((35, 18), 1),))
    assert six(disliked[35]) == "0.280000"  # replaced, not accumulated
    assert _affinity({35: D("0.6")}, (RatedViewing((35,), None),)) == {35: D("0.6")}


def test_genre_affinity_g_and_unknown_genres() -> None:
    assert engine.component_g(set(), {35: D(1)}) == D("0.5")
    assert engine.component_g({35, 18}, {35: D("0.8")}) == D("0.7")


def test_diversity_jaccard() -> None:
    assert engine.component_d({35}, ((35,),)) == 0
    assert engine.component_d({28}, ((35,),)) == 1
    assert engine.component_d({28, 18}, ((18,), (35,))) == D("0.75")
    assert engine.component_d({28}, ()) == D("0.5")
    assert engine.component_d(set(), ((35,),)) == D("0.5")
    # Only the three most recent comparable viewings count.
    assert engine.component_d({28}, ((35,), (35,), (35,), (28,))) == 1


def test_age_and_recency_use_floor_days_and_saturate() -> None:
    just_under = NOW - timedelta(days=1) + timedelta(seconds=1)
    assert engine.component_a(just_under, NOW, CFG) == 0
    assert engine.component_a(NOW - timedelta(days=45), NOW, CFG) == D("0.5")
    assert engine.component_a(NOW - timedelta(days=400), NOW, CFG) == 1
    assert engine.component_a(NOW + timedelta(days=3), NOW, CFG) == 0  # future clamps
    assert engine.component_r(None, NOW, CFG) == 1
    assert engine.component_r(NOW - timedelta(days=1), NOW, CFG) == D(1) / 14
    assert engine.component_r(NOW - timedelta(days=30), NOW, CFG) == 1


def test_quality_shrinkage_and_neutral_missing_votes() -> None:
    assert engine.component_q(D("8.0"), 200, CFG) == D("0.65")
    assert engine.component_q(D("10"), 2, CFG) < D("0.51")  # tiny counts are dampened
    for avg, count in ((None, 10), (D(7), None), (D(7), 0), (D(11), 10)):
        assert engine.component_q(avg, count, CFG) == D("0.5")


# --- ordering and determinism -------------------------------------------------------------


def test_exact_ties_break_by_added_at_then_tmdb_id() -> None:
    older = NOW - timedelta(days=5, hours=1)
    films = [movie(30, added_at=older), movie(20, added_at=older), movie(10)]
    # Same whole-day age gives identical scores; 10 is newer, 20 < 30.
    films[2] = movie(10, added_at=NOW - timedelta(days=5))
    order = [s.candidate.tmdb_id for s in run(films).ranked]
    assert order == [20, 30, 10]


def test_shuffled_input_gives_identical_results() -> None:
    films = [
        movie(i, genre_ids=((i % 5) + 10,), added_at=NOW - timedelta(days=i)) for i in range(1, 60)
    ]
    baseline = run(films, ctx(desired_experience="exciting"))
    rng = random.Random(7)  # noqa: S311  (deterministic shuffle, not security)
    for _ in range(5):
        shuffled = films[:]
        rng.shuffle(shuffled)
        again = run(shuffled, ctx(desired_experience="exciting"))
        assert [(s.candidate.tmdb_id, s.total) for s in again.ranked] == [
            (s.candidate.tmdb_id, s.total) for s in baseline.ranked
        ]


def test_unrelated_added_candidate_never_changes_existing_scores() -> None:
    films = [LOLA, GRAND]
    before = {s.candidate.tmdb_id: s.components for s in run(films, **EXAMPLE).ranked}
    after = {
        s.candidate.tmdb_id: s.components
        for s in run(
            [*films, movie(5, genre_ids=(99,), vote_count=9000, vote_average=D(10))], **EXAMPLE
        ).ranked
    }
    assert after[104] == before[104] and after[120467] == before[120467]


def test_temporary_rejection_inputs_do_not_change_affinity() -> None:
    a = run([LOLA, GRAND], **EXAMPLE)
    b = run([replace(LOLA, offered_this_session=True), GRAND], **EXAMPLE)
    assert a.affinities == b.affinities


def test_five_hundred_candidates_rank_quickly_and_identically() -> None:
    films = [
        movie(
            i,
            genre_ids=(sorted(CFG.intent_genre_map["exciting"])[i % 3], 18),
            added_at=NOW - timedelta(days=i % 120),
            runtime_minutes=80 + i % 70,
            vote_average=D(i % 10),
            vote_count=i * 3,
        )
        for i in range(1, 501)
    ]
    context = ctx(desired_experience="exciting", max_runtime_minutes=120)
    started = time.perf_counter()
    first = run(films, context)
    elapsed = time.perf_counter() - started
    assert first.candidate_count == 500
    assert len(first.ranked) + first.primary_exclusions["runtime_exceeded"] == 500
    assert run(list(reversed(films)), context).winner == first.winner
    assert elapsed < 2, f"500 candidates took {elapsed:.3f}s"


# --- configuration ---------------------------------------------------------------------------


def _raw() -> dict[str, Any]:
    path = Path(engine.__file__).with_name("weights_v1.json")
    return json.loads(path.read_text(encoding="utf-8"), parse_float=Decimal)


def test_config_is_versioned_and_hash_is_stable() -> None:
    assert CFG.version == "weights_v1" and engine.ENGINE_VERSION == "weighted_v1"
    assert sum(CFG.weights.values()) == 100
    assert load_config().hash == CFG.hash and len(CFG.hash) == 64


@pytest.mark.parametrize(
    "mutate",
    [
        lambda r: r["weights"].update(G=36),
        lambda r: r.pop("pace_targets"),
        lambda r: r.update(extra=1),
        lambda r: r["intent_genre_map"].pop("relax"),
        lambda r: r["intent_genre_map"].update(surprise=[35]),
        lambda r: r.update(vote_prior_mean=D("1.5")),
        lambda r: r.update(age_saturation_days=0),
        lambda r: r["pace_targets"].update(high=D("1.2")),
    ],
)
def test_invalid_config_fails_to_load(mutate: Any) -> None:
    raw = _raw()
    mutate(raw)
    with pytest.raises(ValueError):
        parse_config(raw)


def test_scorer_has_no_network_database_clock_or_randomness() -> None:
    tree = ast.parse(Path(engine.__file__).read_text(encoding="utf-8"))
    imported = {
        (n.module or "") if isinstance(n, ast.ImportFrom) else a.name
        for n in ast.walk(tree)
        if isinstance(n, ast.Import | ast.ImportFrom)
        for a in n.names
    }
    assert imported <= {
        "hashlib",
        "json",
        "dataclasses",
        "datetime",
        "decimal",
        "pathlib",
        "typing",
    }
    calls = {
        n.func.attr
        for n in ast.walk(tree)
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
    }
    assert not calls & {"now", "today", "utcnow", "random", "time"}
