"""Deterministic recommendation engine `weighted_v1` (RECOMMENDATION_ENGINE.md).

`rank(RankingInput, EngineConfig) -> RankingResult` is pure: no network,
database, clock, randomness or model access. The service passes every input,
including the evaluation time and the user's local date.
"""

import hashlib
import json
from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import ROUND_HALF_EVEN, Context, Decimal, localcontext
from pathlib import Path
from typing import Any

ENGINE_VERSION = "weighted_v1"
COMPONENTS = ("G", "C", "D", "A", "R", "Q")
INTENTS = (
    "make_me_laugh",
    "comfort",
    "feel_it",
    "relax",
    "deep",
    "exciting",
    "keep_me_hooked",
    "surprise",
)
# Primary exclusion precedence; the first applicable code is the one counted.
EXCLUSIONS = (
    "movie_unavailable",
    "already_watched",
    "movie_blocked",
    "offered_this_session",
    "genre_blocked",
    "runtime_unknown",
    "runtime_exceeded",
)
RATING_EVIDENCE = {
    1: Decimal(-1),
    2: Decimal("-0.5"),
    3: Decimal(0),
    4: Decimal("0.5"),
    5: Decimal(1),
}

_DEC = Context(prec=28, rounding=ROUND_HALF_EVEN)
ZERO, HALF, ONE = Decimal(0), Decimal("0.5"), Decimal(1)
INTENT_MATCH, INTENT_MISS = Decimal("0.8"), Decimal("0.2")
SECONDS_PER_DAY = 86400

# --- configuration ----------------------------------------------------------------


@dataclass(frozen=True)
class EngineConfig:
    version: str
    weights: dict[str, Decimal]
    genre_prior_strength: Decimal
    age_saturation_days: Decimal
    recency_saturation_days: Decimal
    vote_prior_strength: Decimal
    vote_prior_mean: Decimal
    intent_genre_map: dict[str, frozenset[int]]
    pace_targets: dict[str, Decimal]
    learned_reason_support: Decimal
    reason_affinity_threshold: Decimal
    snapshot: dict[str, Any]  # exact canonical JSON, stored per run
    hash: str


def canonical_json(value: Any) -> str:
    """Sorted keys, compact UTF-8; Decimals as their exact string form."""
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
        default=str,
    )


def _dec(raw: Any, name: str, lo: Decimal, hi: Decimal | None = None) -> Decimal:
    if isinstance(raw, bool) or not isinstance(raw, int | Decimal):
        raise ValueError(f"{name} must be a number")
    value = Decimal(raw)
    if not value.is_finite() or value < lo or (hi is not None and value > hi):
        raise ValueError(f"{name} out of range")
    return value


def parse_config(raw: dict[str, Any]) -> EngineConfig:
    """Fails on missing keys, invalid ranges or weights not summing to 100.
    Numbers must be parsed as Decimal (json `parse_float=Decimal`)."""
    keys = {
        "config_version",
        "weights",
        "genre_prior_strength",
        "age_saturation_days",
        "recency_saturation_days",
        "vote_prior_strength",
        "vote_prior_mean",
        "intent_genre_map",
        "pace_targets",
        "learned_reason_support",
        "reason_affinity_threshold",
    }
    if set(raw) != keys:
        raise ValueError(f"config keys must be exactly {sorted(keys)}")
    weights = raw["weights"]
    if not isinstance(weights, dict) or set(weights) != set(COMPONENTS):
        raise ValueError("weights must name G, C, D, A, R and Q")
    w = {k: _dec(weights[k], f"weights.{k}", ZERO, Decimal(100)) for k in COMPONENTS}
    if sum(w.values()) != 100:
        raise ValueError("weights must sum to 100")
    intents = raw["intent_genre_map"]
    if not isinstance(intents, dict) or set(intents) != set(INTENTS):
        raise ValueError("intent_genre_map must cover every desired experience")
    if intents["surprise"] != []:
        raise ValueError("surprise has no intent genres")
    intent_map: dict[str, frozenset[int]] = {}
    for name, ids in intents.items():
        if not isinstance(ids, list) or not all(
            isinstance(i, int) and not isinstance(i, bool) and i > 0 for i in ids
        ):
            raise ValueError(f"intent_genre_map.{name} must be genre ids")
        intent_map[name] = frozenset(ids)
    pace = raw["pace_targets"]
    if not isinstance(pace, dict) or set(pace) != {"low", "medium", "high"}:
        raise ValueError("pace_targets must define low, medium and high")
    version = raw["config_version"]
    if not isinstance(version, str) or not version:
        raise ValueError("config_version must be a string")
    positive = Decimal("0.000001")
    snapshot = json.loads(canonical_json(raw), parse_float=Decimal)
    return EngineConfig(
        version=version,
        weights=w,
        genre_prior_strength=_dec(raw["genre_prior_strength"], "genre_prior_strength", positive),
        age_saturation_days=_dec(raw["age_saturation_days"], "age_saturation_days", ONE),
        recency_saturation_days=_dec(
            raw["recency_saturation_days"], "recency_saturation_days", ONE
        ),
        vote_prior_strength=_dec(raw["vote_prior_strength"], "vote_prior_strength", positive),
        vote_prior_mean=_dec(raw["vote_prior_mean"], "vote_prior_mean", ZERO, ONE),
        intent_genre_map=intent_map,
        pace_targets={k: _dec(pace[k], f"pace_targets.{k}", ZERO, ONE) for k in pace},
        learned_reason_support=_dec(raw["learned_reason_support"], "learned_reason_support", ZERO),
        reason_affinity_threshold=_dec(
            raw["reason_affinity_threshold"], "reason_affinity_threshold", ZERO, ONE
        ),
        snapshot=snapshot,
        hash=hashlib.sha256(canonical_json(snapshot).encode()).hexdigest(),
    )


def load_config(path: Path | None = None) -> EngineConfig:
    path = path or Path(__file__).with_name("weights_v1.json")
    return parse_config(json.loads(path.read_text(encoding="utf-8"), parse_float=Decimal))


# --- inputs and results -------------------------------------------------------------


@dataclass(frozen=True)
class Candidate:
    """One active watchlist entry with the facts the engine may use."""

    tmdb_id: int
    added_at: datetime
    release_date: date | None
    runtime_minutes: int | None
    genre_ids: tuple[int, ...]
    adult: bool = False
    metadata_ready: bool = True
    vote_average: Decimal | None = None
    vote_count: int | None = None
    last_offered_at: datetime | None = None
    watched: bool = False
    blocked: bool = False
    offered_this_session: bool = False
    # Curated traits in [0,1] (P6 enrichment). None means unknown.
    pace: Decimal | None = None
    complexity: Decimal | None = None
    heaviness: Decimal | None = None


@dataclass(frozen=True)
class EffectiveContext:
    """Profile limits already combined (min cap, union of avoided genres,
    blocked ids removed from preferred). current_mood is not an input."""

    desired_experience: str
    max_runtime_minutes: int | None = None
    pace: str | None = None
    complexity_max: Decimal | None = None
    heaviness_max: Decimal | None = None
    prefer_genre_ids: frozenset[int] = frozenset()
    avoid_genre_ids: frozenset[int] = frozenset()


@dataclass(frozen=True)
class RatedViewing:
    genre_ids: tuple[int, ...]
    rating: int | None


@dataclass(frozen=True)
class RankingInput:
    candidates: tuple[Candidate, ...]
    context: EffectiveContext
    local_date: date
    evaluation_time: datetime
    # Explicit genre preferences p_g in [-1,1]; missing genres are 0.
    genre_preferences: dict[int, Decimal] = field(default_factory=dict)
    # Every viewing with its rating (P5); empty before history exists.
    rated_viewings: tuple[RatedViewing, ...] = ()
    # Up to three most recent viewings' nonempty genre snapshots, newest first.
    recent_genre_sets: tuple[tuple[int, ...], ...] = ()


@dataclass(frozen=True)
class Reason:
    code: str
    values: dict[str, Any]
    source: str


@dataclass(frozen=True)
class Scored:
    candidate: Candidate
    rank: int
    total: Decimal
    components: dict[str, Decimal]
    contributions: dict[str, Decimal]
    reasons: tuple[Reason, ...]
    uncertainties: tuple[Reason, ...]


@dataclass(frozen=True)
class RankingResult:
    ranked: tuple[Scored, ...]  # eligible films, best first
    candidate_count: int
    primary_exclusions: dict[str, int]
    affinities: dict[int, Decimal]
    affinity_support: dict[int, Decimal]

    @property
    def winner(self) -> Scored | None:
        return self.ranked[0] if self.ranked else None


# --- filters -------------------------------------------------------------------------


def exclusions(c: Candidate, ctx: EffectiveContext, local_date: date) -> list[str]:
    """Every applicable code, in precedence order."""
    codes = []
    if not c.metadata_ready or c.adult or c.release_date is None or c.release_date > local_date:
        codes.append("movie_unavailable")
    if c.watched:
        codes.append("already_watched")
    if c.blocked:
        codes.append("movie_blocked")
    if c.offered_this_session:
        codes.append("offered_this_session")
    if ctx.avoid_genre_ids & set(c.genre_ids):
        codes.append("genre_blocked")
    cap = ctx.max_runtime_minutes
    if cap is not None and c.runtime_minutes is None:
        codes.append("runtime_unknown")
    if cap is not None and c.runtime_minutes is not None and c.runtime_minutes > cap:
        codes.append("runtime_exceeded")
    return codes


# --- components ----------------------------------------------------------------------


def _clamp(x: Decimal, lo: Decimal, hi: Decimal) -> Decimal:
    return max(lo, min(hi, x))


def _mean(values: list[Decimal]) -> Decimal:
    return sum(values, ZERO) / len(values)


def genre_affinities(
    inp: RankingInput, cfg: EngineConfig
) -> tuple[dict[int, Decimal], dict[int, Decimal]]:
    """affinity_g = clamp((k*p_g + sum(w*r)) / (k + sum(w)), -1, 1) with prior
    strength k; a rated film with n genres gives each genre w = 1/n. Returns
    (affinity, support) for every genre with a preference or evidence."""
    evidence: dict[int, Decimal] = {}
    support: dict[int, Decimal] = {}
    for viewing in inp.rated_viewings:
        if viewing.rating is None or not viewing.genre_ids:
            continue
        r = RATING_EVIDENCE[viewing.rating]
        genres = sorted(set(viewing.genre_ids))
        w = ONE / len(genres)
        for g in genres:
            evidence[g] = evidence.get(g, ZERO) + w * r
            support[g] = support.get(g, ZERO) + w
    k = cfg.genre_prior_strength
    affinities = {}
    for g in sorted(set(inp.genre_preferences) | set(support)):
        p = inp.genre_preferences.get(g, ZERO)
        s = support.get(g, ZERO)
        affinities[g] = _clamp((k * p + evidence.get(g, ZERO)) / (k + s), -ONE, ONE)
    return affinities, support


def component_g(genres: set[int], affinities: dict[int, Decimal]) -> Decimal:
    if not genres:
        return HALF
    return (ONE + _mean([affinities.get(g, ZERO) for g in sorted(genres)])) / 2


def _upper_target_match(x: Decimal | None, m: Decimal) -> Decimal:
    if x is None:
        return HALF
    if x <= m or m == ONE:
        return ONE
    return max(ZERO, ONE - (x - m) / (ONE - m))


def context_dimensions(
    c: Candidate, ctx: EffectiveContext, cfg: EngineConfig
) -> dict[str, Decimal]:
    """Requested dimensions only; each is equally weighted inside C."""
    genres = set(c.genre_ids)
    dims: dict[str, Decimal] = {}
    if ctx.desired_experience != "surprise":
        if not genres:
            dims["intent"] = HALF
        else:
            hit = genres & cfg.intent_genre_map[ctx.desired_experience]
            dims["intent"] = INTENT_MATCH if hit else INTENT_MISS
    if ctx.pace is not None:
        target = cfg.pace_targets[ctx.pace]
        dims["pace"] = HALF if c.pace is None else ONE - abs(c.pace - target)
    if ctx.complexity_max is not None:
        dims["complexity"] = _upper_target_match(c.complexity, ctx.complexity_max)
    if ctx.heaviness_max is not None:
        dims["heaviness"] = _upper_target_match(c.heaviness, ctx.heaviness_max)
    if ctx.prefer_genre_ids:
        dims["prefer_genres"] = (
            HALF if not genres else (ONE if genres & ctx.prefer_genre_ids else ZERO)
        )
    return dims


def component_d(genres: set[int], recent: tuple[tuple[int, ...], ...]) -> Decimal:
    comparable = [set(h) for h in recent[:3] if h]
    if not genres or not comparable:
        return HALF
    jaccards = [Decimal(len(genres & h)) / Decimal(len(genres | h)) for h in comparable]
    return ONE - _mean(jaccards)


def _whole_days(later: datetime, earlier: datetime) -> int:
    return max(0, int((later - earlier).total_seconds() // SECONDS_PER_DAY))


def component_a(added_at: datetime, now: datetime, cfg: EngineConfig) -> Decimal:
    return min(Decimal(_whole_days(now, added_at)) / cfg.age_saturation_days, ONE)


def component_r(last_offered_at: datetime | None, now: datetime, cfg: EngineConfig) -> Decimal:
    if last_offered_at is None:
        return ONE
    return min(Decimal(_whole_days(now, last_offered_at)) / cfg.recency_saturation_days, ONE)


def component_q(average: Decimal | None, count: int | None, cfg: EngineConfig) -> Decimal:
    if average is None or count is None or count <= 0 or not ZERO <= average <= 10:
        return HALF
    v, k = Decimal(count), cfg.vote_prior_strength
    return (v / (v + k)) * (average / 10) + (k / (v + k)) * cfg.vote_prior_mean


# --- reasons ---------------------------------------------------------------------------


def _reasons(
    c: Candidate,
    ctx: EffectiveContext,
    dims: dict[str, Decimal],
    contributions: dict[str, Decimal],
    inp: RankingInput,
    affinities: dict[int, Decimal],
    support: dict[int, Decimal],
    cfg: EngineConfig,
) -> tuple[tuple[Reason, ...], tuple[Reason, ...]]:
    """Up to two factual reasons (runtime fit first, then the strongest
    positive contributions with a supported fact) plus uncertainties."""
    reasons: list[Reason] = []
    if ctx.max_runtime_minutes is not None and c.runtime_minutes is not None:
        reasons.append(
            Reason(
                "fits_runtime",
                {"runtime_minutes": c.runtime_minutes, "cap_minutes": ctx.max_runtime_minutes},
                "metadata",
            )
        )
    genres = sorted(set(c.genre_ids))
    supported: dict[str, Reason] = {}
    explicit = [g for g in genres if inp.genre_preferences.get(g, ZERO) > 0]
    learned = [
        g
        for g in genres
        if support.get(g, ZERO) >= cfg.learned_reason_support
        and affinities.get(g, ZERO) >= cfg.reason_affinity_threshold
    ]
    if explicit:
        supported["G"] = Reason("explicit_genre_match", {"genre_ids": explicit}, "preferences")
    elif learned:
        supported["G"] = Reason("learned_genre_match", {"genre_ids": learned}, "history")
    intent_hits = sorted(set(genres) & cfg.intent_genre_map.get(ctx.desired_experience, set()))
    if intent_hits:
        supported["C"] = Reason(
            "context_genre_proxy",
            {"desired_experience": ctx.desired_experience, "genre_ids": intent_hits},
            "context",
        )
    elif dims.get("prefer_genres") == ONE:
        supported["C"] = Reason(
            "tonight_genre_match",
            {"genre_ids": sorted(set(genres) & ctx.prefer_genre_ids)},
            "context",
        )
    if inp.recent_genre_sets and genres:
        supported["D"] = Reason(
            "variety", {"recent_count": len(inp.recent_genre_sets[:3])}, "history"
        )
    age = _whole_days(inp.evaluation_time, c.added_at)
    if age >= 30:
        supported["A"] = Reason("waiting_in_watchlist", {"age_days": age}, "watchlist")
    if c.last_offered_at is None:
        supported["R"] = Reason("not_offered_before", {}, "history")
    else:
        days = _whole_days(inp.evaluation_time, c.last_offered_at)
        supported["R"] = Reason("not_offered_recently", {"days": days}, "history")
    if c.vote_average is not None and c.vote_count:
        supported["Q"] = Reason(
            "tmdb_rating",
            {"vote_average": str(c.vote_average), "vote_count": c.vote_count},
            "tmdb",
        )
    positive = sorted(
        (k for k in COMPONENTS if contributions[k] > 0 and k in supported),
        key=lambda k: (-contributions[k], COMPONENTS.index(k)),
    )
    for k in positive:
        if len(reasons) >= 2:
            break
        reasons.append(supported[k])
    if not any(r.code != "fits_runtime" for r in reasons):
        reasons.append(Reason("best_remaining_match", {}, "engine"))
    uncertain = [
        Reason("unknown_trait", {"trait": t}, "metadata")
        for t, requested, known in (
            ("pace", ctx.pace is not None, c.pace is not None),
            ("complexity", ctx.complexity_max is not None, c.complexity is not None),
            ("heaviness", ctx.heaviness_max is not None, c.heaviness is not None),
        )
        if requested and not known
    ]
    if not genres and ctx.desired_experience != "surprise":
        uncertain.append(Reason("unknown_genres", {}, "metadata"))
    return tuple(reasons), tuple(uncertain)


# --- ranking ---------------------------------------------------------------------------


def score(
    c: Candidate,
    inp: RankingInput,
    cfg: EngineConfig,
    affinities: dict[int, Decimal],
) -> tuple[Decimal, dict[str, Decimal], dict[str, Decimal], dict[str, Decimal]]:
    """(total, components, contributions above-neutral, context dims)."""
    genres = set(c.genre_ids)
    dims = context_dimensions(c, inp.context, cfg)
    components = {
        "G": component_g(genres, affinities),
        "C": _mean(list(dims.values())) if dims else HALF,
        "D": component_d(genres, inp.recent_genre_sets),
        "A": component_a(c.added_at, inp.evaluation_time, cfg),
        "R": component_r(c.last_offered_at, inp.evaluation_time, cfg),
        "Q": component_q(c.vote_average, c.vote_count, cfg),
    }
    total = sum((cfg.weights[k] * components[k] for k in COMPONENTS), ZERO)
    above_neutral = {k: cfg.weights[k] * (components[k] - HALF) for k in COMPONENTS}
    return total, components, above_neutral, dims


def rank(inp: RankingInput, cfg: EngineConfig) -> RankingResult:
    with localcontext(_DEC):
        affinities, support = genre_affinities(inp, cfg)
        counts: dict[str, int] = {}
        scored: list[
            tuple[Decimal, Candidate, dict[str, Decimal], tuple[Reason, ...], tuple[Reason, ...]]
        ] = []
        for c in inp.candidates:
            codes = exclusions(c, inp.context, inp.local_date)
            if codes:
                counts[codes[0]] = counts.get(codes[0], 0) + 1
                continue
            total, components, above, dims = score(c, inp, cfg, affinities)
            reasons, uncertain = _reasons(
                c, inp.context, dims, above, inp, affinities, support, cfg
            )
            scored.append((total, c, components, reasons, uncertain))
        scored.sort(key=lambda s: (-s[0], s[1].added_at, s[1].tmdb_id))
        ranked = tuple(
            Scored(
                candidate=c,
                rank=i + 1,
                total=total,
                components=components,
                contributions={k: cfg.weights[k] * components[k] for k in COMPONENTS},
                reasons=reasons,
                uncertainties=uncertain,
            )
            for i, (total, c, components, reasons, uncertain) in enumerate(scored)
        )
    return RankingResult(
        ranked=ranked,
        candidate_count=len(inp.candidates),
        primary_exclusions={k: counts[k] for k in EXCLUSIONS if k in counts},
        affinities=affinities,
        affinity_support=support,
    )
