# Cinemé — deterministic recommendation engine V1

Version `weighted_v1`; weight configuration `weights_v1`. This is a content-based weighted scorer, not a trained model and not a probability estimator.

## Contract and order

`rank(RankingInput, EngineConfig) -> RankingResult` is pure. Given the same full RankingInput fixture and config it returns the same filters, components, rank order, reason codes and winner. The service provides the time, IDs and metadata; engine imports only standard library/typed domain definitions.

Order: assemble candidates -> apply hard filters -> derive genre affinity -> calculate normalized components -> weight and sum -> deterministic tie break -> generate reason data. The service persists the winner, aggregate exclusion counts and at most nine runners-up; the rest of the full result is discarded after selection. Full deterministic fixtures are retained in tests, not every production attempt. No network/LLM calls anywhere in this path.

## Candidate set and hard filters

Start with all active watchlist entries owned by the user, at most 500. Removed films are not candidates. Evaluate/filter all active candidates in memory; do not write an audit row for each. Apply exclusions in this ordered precedence:

1. `movie_unavailable`: unavailable details, adult flag, unknown release date or release date after user's current local date.
2. `already_watched`: known viewing exists for user/movie.
3. `movie_blocked`: explicit user/movie block.
4. `offered_this_session`: any earlier selection attempt in today's session chose this movie, including superseded/accepted/rejected records. Initial choose returns an existing current offered/accepted pick before invoking the engine.
5. `genre_blocked`: movie intersects union of permanent blocked genres and tonight's avoid list.
6. `runtime_unknown`: an effective cap exists but movie runtime is null.
7. `runtime_exceeded`: runtime > effective inclusive cap.

Compute every applicable code transiently, but use the first applicable code as the primary exclusion for mutually exclusive no-match counts. This prevents double-counting: primary counts sum to the candidate count when none qualify.

Permanent and tonight caps combine as `min(non-null caps)`; no caps means no runtime filter. Blocked genres combine by union; remove them from effective preferred genres and expose the override. A known-runtime film exactly at cap is eligible. Trait targets (pace/complexity/heaviness) are soft because metadata coverage is incomplete. If a user types a hard content safety request V1 cannot support, show an unsupported-constraint warning; do not claim enforcement.

Rewatches do not exist in V1. No fallback outside the watchlist. No fallback to a blocked film. Unknown genre does not establish a banned genre, so it stays eligible but receives neutral genre/context evidence and an uncertainty note. These are genre exclusions, not a guarantee about specific content.

## Components and weights

All component values are in [0,1]. Higher is better. Default total:

`score = 35*G + 30*C + 10*D + 10*A + 10*R + 5*Q`

| Symbol | Component | Weight | Missing-data policy |
|---|---|---:|---|
| G | Long-term genre affinity | 35 | Unknown genres -> 0.5 |
| C | Desired viewing experience and other requested soft context | 30 | No requested dimensions -> 0.5; unknown requested trait -> 0.5 |
| D | Diversity versus last three known viewings | 10 | No comparable history/genres -> 0.5 |
| A | Time waiting in watchlist | 10 | Entry date is required; invalid future date clamps to zero |
| R | Recommendation recency | 10 | Never offered -> 1 |
| Q | Shrunk TMDB vote average | 5 | Missing or unusable vote evidence -> 0.5 |

Do not use candidate-set min/max normalization: adding a film should not change another film's component scores. Do not redistribute weights because a field is missing. A missing field is explicit uncertainty, not extra influence for popularity.

Runtime fit is a filter in V1, not another weighted component. Within the cap, shorter is not inherently better. User rating history is already represented by G; adding a separate rating-history score would double-count it. All watched films are excluded, so “recently watched” is not a separate movie penalty. Rejection is scoped exclusions/context plus recency, not a second taste model.

## G: genre affinity with conservative learning

Explicit preference `p_g` is [-1,1], default zero. Preferred genre selection in simple onboarding writes +0.6; profile advanced slider may choose any allowed value. Permanent exclusion uses blocked genres, not a -1 slider value.

Ratings map to evidence values:

| Rating | Evidence r |
|---|---:|
| loved | +1.0 |
| liked | +0.5 |
| okay | 0.0 |
| disliked | -1.0 |
| null | No observation |

For a rated film with k snapshot genres, allocate weight `w=1/k` to each genre. This prevents a six-genre film contributing six full observations. For each genre:

`affinity_g = clamp((2*p_g + sum(w*r)) / (2 + sum(w)), -1, 1)`

The prior strength is 2 equivalent observations. For a movie with genre set M:

`G = (1 + mean(affinity_g for g in M)) / 2`

Empty M -> G=0.5. Store the evidence support `sum(w)` separately for explanations; do not call one positive rating a strong preference. For learned-reason wording, require support >=2 and affinity >=0.2. Explicit preference can explain a genre match without this support threshold.

One viewing/movie and its current rating is the only observation. Rating edits recompute from source records; no incremental hidden counters. Genre snapshots on viewing are frozen, so later TMDB genre changes do not rewrite past learning. There is no temporal decay, implicit watchlist-distribution preference, actor/director learning or mood-rating cross-model in V1.

Example: explicit comedy p=0.6; one two-genre loved film adds w=0.5. New comedy affinity=(1.2+0.5)/(2+0.5)=0.68. Replacing that rating with disliked produces (1.2-0.5)/2.5=0.28, not two observations. A temporary rejection changes neither value.

## C: requested context only

Compute the arithmetic mean of requested dimensions below. Each dimension has equal weight within C. No requested dimension -> C=0.5. Track coverage as known/requested dimensions; coverage is explanatory only, not an extra score.

### Desired-experience compatibility (explicit heuristic)

`current_mood` is metadata for the user-facing follow-up only. It never enters score/filter logic. `desired_experience` is the user's confirmed viewing intent, distinct from emotion. API requires an initial intent or explicit Surprise me.

| Desired experience | Approximate compatible TMDB genre IDs |
|---|---|
| make_me_laugh | Comedy35 |
| comfort | Family10751, Animation16, Comedy35 |
| feel_it | Drama18, Romance10749 |
| relax | Comedy35, Family10751, Adventure12 |
| deep | Drama18, Science Fiction878, Mystery9648 |
| exciting | Action28, Adventure12, Thriller53 |
| keep_me_hooked | Thriller53, Mystery9648, Crime80 |
| surprise | No intent dimension: use other signals, never random selection |

For any nonsurprise intent, known genres give0.8 if any matches,0.2 otherwise; unknown genres give0.5. Surprise omits this dimension rather than secretly favoring novelty. These are genre heuristics, not guarantees that a comedy will cheer someone up or an adventure will relax them. Explain “its genres align with your requested experience,” not “because you are sad, comedy will fix it.”

Examples: `current_mood=down,desired_experience=make_me_laugh` prefers comedy; the same mood with `feel_it` prefers drama/romance. Down alone returns a request for desired experience before selection, not an automatic comedy recommendation.

### Pace

Request enum low/medium/high maps target t to 0.15/0.50/0.85. Curated movie pace x in [0,1] gives `pace_match=1-abs(x-t)`. Null trait ->0.5. High pacing is independent of low complexity; do not automatically infer one from the other.

### Complexity/heaviness upper targets

For requested soft maximum m in [0,1] and known trait x:

- If x <= m, match=1.
- Otherwise `match=max(0, 1-(x-m)/(1-m))`.
- If m=1, match=1 for every known x (avoid zero division).
- Unknown x ->0.5, always with an uncertainty flag.

Only human-curated values are accepted in V1. These traits are optional enrichment: absence of the table/dataset at early phases or zero rows must map to null traits without breaking ranking. Requested maxima are preferences, not hard guarantees. No text embedding of overview. No LLM judging candidate traits.

### Tonight's preferred genres

If `prefer_genre_ids` is nonempty, match=1 if any movie genre overlaps, 0 otherwise, 0.5 for unknown genres. This is a context dimension, separate from global G. Tonight's avoided genres are hard exclusions, not this component. Lists must be disjoint.

## D: small diversity signal

Compare candidate genres with the last up to three viewings that have nonempty genre snapshots. Recency sorts by `COALESCE(watched_at,recorded_at) DESC`, then ID. Unknown watched dates use recording time as a disclosed proxy; this is not a claim about when the film was actually watched.

For genre sets M and H, `Jaccard(M,H)=|M intersection H|/|M union H|`.

`D=1-mean(Jaccard(M,H) for available H)`.

No candidate genres or no comparable H ->0.5. Same genres as all recent movies ->0. Entirely different ->1. Ten points maximum means variety cannot override hard constraints or dominate taste. No rule forbids two comedies in a row.

## A: watchlist age

`age_days=max(0, floor((evaluation_time-added_at).total_seconds()/86400))`

`A=min(age_days/90,1)`.

The 90-day saturation is a versioned config parameter. Restoring an archived entry resets age. Old movies are not automatically high quality; this is a small nudge to stop indefinitely postponing them.

## R: recommendation recency

If never offered, R=1. Otherwise:

`R=min(max(0,floor((evaluation_time-last_offered_at)/86400))/14,1)`.

Last offered means any historical recommendation with this movie, regardless of acceptance/rejection/supersession. Offered-this-session is already excluded. A film offered yesterday gets R=1/14; 14+ days ago gets R=1.

This generic anti-repetition effect applies after both accepted and rejected offers; it is not a permanent dislike inference. “Not tonight” expires as an exclusion at that session's boundary, while all prior offers participate in this neutral recency component.

## Q: external votes as a minor signal

With valid vote count v and average a in [0,10]:

`Q=(v/(v+200))*(a/10)+(200/(v+200))*0.5`.

Missing count/average ->0.5; v=0 ->0.5. Prior strength 200 and prior mean 0.5 are fixed config defaults, not hidden live global averages. This caps popularity influence at five points and dampens tiny vote counts. Do not use popularity/trending/rating simultaneously.

## Precision, determinism and bounded storage

Keep Decimal arithmetic, precision28 and ROUND_HALF_EVEN. Compute without intermediate display rounding; sort by unrounded total descending, added_at ascending, TMDB ID ascending. Stable order for genre IDs, rating evidence, recent history and components G,C,D,A,R,Q. Public scores round to two decimals; component summaries to six. Hash canonical finite JSON with sorted keys/compact UTF-8 serialization.

The pure scorer returns the full transient result for service selection/tests. Production persists only: winner display snapshot/score inputs/components/contributions/reasons; engine version; exact config snapshot/hash; requested/effective context plus small shared explanation inputs (genre affinity/support and up to three watched genre snapshots); primary exclusion totals; up to nine eligible runners-up with their score inputs/breakdowns and original rank. Ten retained films maximum, never500 database rows. Excluded films are represented by counts, not individual stored metadata. No additional candidate-score table or full input snapshot.

Snapshot selected-film display metadata so old cards agree with old explanations after metadata updates. Retained comparison records can recompute their own components using saved inputs/config. They cannot prove the complete historical candidate set or replay all rejected candidates. Complete ranking reproducibility is demonstrated with versioned full fixtures in the test suite. Do not claim full production-run replay from partial data.

Comparison sampling follows the same rank order, stores ranks2..10, and is capped at nine or fewer. Its payload is bounded to64KiB total recommendation evidence, excluding the short main explanation; drop trailing runners-up if necessary and set comparisons_truncated=true. Winner/config/context cannot be dropped. Avoid ingesting entire overviews/poster binaries into snapshots. Normal declared sizes must fit; oversized mandatory evidence is an explicit error, not silent truncation of the winner.

## Reasons and explanations

Emit reason codes with source and values, not generated facts. Required hard-constraint facts can be shown even though they are filters, not weighted “reasons.” Examples:

- `fits_runtime`: runtime/cap; “81 minutes, within your 100-minute limit.”
- `explicit_genre_match`: genre/preference values.
- `learned_genre_match`: support/affinity, only with threshold above.
- `context_genre_proxy`: confirmed desired experience and matching genre, explicitly heuristic.
- `curated_pace_match`: known trait/source and requested pace.
- `curated_complexity_match`: known trait/source and preference match.
- `variety`: overlap data versus recent viewing snapshot.
- `waiting_in_watchlist`: age days when >=30.
- `unknown_trait`: missing requested field, not a positive reason.

Template policy: first state runtime fit if there is a cap and known runtime. Then use the strongest positive contribution above its neutral baseline (`weight*(component-0.5)`), selecting a reason actually supported by known subfields. Resolve equal reason contributions in component order G,C,D,A,R,Q. Recency/quality alone get modest wording. If no positive supported reason exists: “This is the best remaining match under tonight's constraints.” Add a concise uncertainty statement if requested traits are unknown. Never invent genre/style/actor/provider facts. Do not claim optimality beyond this bounded rule set.

Today shows up to two concise reasons plus uncertainty; detailed drawer shows all components and the algorithm version. The bounded comparison endpoint includes only retained scored films and aggregate exclusion counts. It is not rendered on Tonight or used to offer alternate actions.

## Worked example with real movie names

The runtime/genre references are TMDB pages for [Run Lola Run](https://www.themoviedb.org/movie/104-lola-rennt), [The Grand Budapest Hotel](https://www.themoviedb.org/movie/120467-the-grand-budapest-hotel), and [Arrival](https://www.themoviedb.org/movie/329865-arrival). Other numbers below are synthetic, explicitly defined test inputs, not live TMDB votes or objective movie-trait truth. Live application metadata comes from the API.

Context: cap=100, desired_experience=exciting, pace=high, complexity_max=0.45. All movies are unblocked, active and not watched/offered today. Most recent comparable viewing has genre set {Comedy,Drama}; only one history comparison. Precomputed affinities: Action=.4, Drama=0, Thriller=.5, Comedy=.8, other genres=0. This fixture can result from explicit profile values without rated history.

| Movie | Runtime | Genres | Curated pace | Complexity | Age days | Last offer | Synthetic votes |
|---|---:|---|---:|---:|---:|---|---|
| Run Lola Run | 81 | Action, Drama, Thriller | .90 | .40 | 30 | Never | v=200,a=8.0 |
| The Grand Budapest Hotel | 100 | Comedy, Drama | .70 | .55 | 90 | 7 full days ago | v=200,a=9.0 |
| Arrival | 116 | Drama, Science Fiction, Mystery | Unknown | Unknown | 60 | Never | Not scored |

Run Lola Run: G=(1+(.4+0+.5)/3)/2=.65. C=(.8+.95+1)/3=.9166666667. Jaccard overlap=1/4, so D=.75. A=30/90, R=1, Q=.65.

Grand Budapest: G=(1+(.8+0)/2)/2=.70. Complexity match=1-(.55-.45)/(.55)=.8181818182. C=(.2+.85+.8181818182)/3=.6227272727. D=0, A=1, R=.5, Q=.70.

| Movie | 35G | 30C | 10D | 10A | 10R | 5Q | Total | Result |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| Run Lola Run | 22.75 | 27.50 | 7.50 | 3.333333 | 10.00 | 3.25 | **74.333333** | Rank 1 |
| The Grand Budapest Hotel | 24.50 | 18.681818 | 0.00 | 10.00 | 5.00 | 3.50 | **61.681818** | Rank 2 |
| Arrival | — | — | — | — | — | — | null | Excluded: runtime_exceeded |

Explanation: “81 minutes, within your 100-minute limit. Its genres and reviewed pacing fit tonight's exciting, faster-paced request.” Curated complexity is subjective; do not say “guaranteed easy viewing.”

### Context changes the winner

Change to desired_experience=relax, no pace request, complexity_max=.45. Other inputs stay fixed, and treat this as an independent fixture with no previously offered movies. Lola C=(.2+1)/2=.6 -> total **64.833333**. Grand C=(.8+.8181818182)/2=.8090909091 -> total **67.272727**. Grand wins. Actual same-session context replacement would exclude a movie already offered that day under I09; this example isolates scoring, not lifecycle.

### Rejection is not dislike

Starting from the first actual session, reject Lola as `not_tonight`. Affinities and rating evidence remain exactly unchanged. Lola is excluded for this session; Grand becomes the next choice at 61.681818. On another day Lola is eligible, with the general recency penalty reflecting the previous offer. If the cap is reduced to 90, Grand and Arrival fail runtime and Lola is already offered: no match. The engine must not relax the cap.

## Cold start and thin data

No explicit preferences or ratings -> G=.5 for every known genre set. Explicit Surprise me without other soft dimensions ->C=.5; no viewing history ->D=.5. Age, recency and small quality signal still distinguish candidates. With one eligible film, choose it regardless of a low soft score and disclose known conflicts. With zero eligible films, return no match. There is no fake “confidence 94%” output.

## Configuration and later evolution

Versioned JSON includes weights, genre prior strength=2, age saturation=90, recency saturation=14, external vote prior strength=200/mean=.5, desired-experience genre map, pace targets, learned-reason support=2, reason affinity threshold=.2. Loading fails on invalid ranges, missing keys or sum !=100. Config hash is saved per run.

Start with this hand-chosen baseline. Capture accept/reject/complete rates, scope-correct feedback and context coverage. A small deterministic offline suite verifies behavioral expectations; it cannot establish real recommendation quality. Later compare weight variants against consented histories and human judgments; avoid fitting to acceptance alone because availability/time also affects it. No automated online weight changes in V1. New major signals require new data contracts and engine versions.

## Required tests

Filters and primary exclusion counts; missing/null boundary cases; cap equality; desired-experience matrix and emotion-independence; pace targets; trait maximum at 0/1; rating shrinkage and edits; no learning from rejection; multigenre allocation; diversity Jaccard; floor-day/saturation boundaries; quality shrinkage; weight sum; shuffled candidate input; exact ties; complete test-fixture replay and bounded stored-comparison checks; worked-example totals; no network access. Include a metamorphic test that an unrelated added candidate never changes existing component scores.

## No-enrichment baseline and product boundary

Core signals come from runtime/genre metadata when known, preferences, history, watchlist dates, earlier offers and shrunk external votes. Metadata is not literally always available: null policies still apply. Pace/complexity/heaviness are optional additions, not prerequisites. An empty trait dataset must pass all functional release gates. Existing synthetic worked examples exercise enhanced metadata; also test the same fixtures with all traits null. With exciting intent and requested unknown pace/complexity, C=(.8+.5+.5)/3=.6 for Lola and (.2+.5+.5)/3=.4 for Grand. Totals are64.833333 and55.000000 respectively; the engine remains usable and admits uncertainty.

Return ONE selected film through Today regardless of watchlist size. No recommendation feed/alternate cards. After three temporary rejections, selection service pauses rather than continuously re-rolling; this is orchestration, not an extra score penalty. Same input plus Surprise me stays deterministic. Different emotional labels with identical desired experience and other inputs must have identical ranks.
