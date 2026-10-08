# ADR 011 — Shows and anime: Tonight recommends one movie or one next episode

Status: **proposed** for review, 2026-10-08. Nothing in this ADR is implemented. Design, contracts and plan: [SERIES_DESIGN.md](../SERIES_DESIGN.md). It becomes accepted when the project owner approves the implementation scope; the series release version is assigned then.

## Decision

1. **The "No TV" non-goal in `PROJECT_SPEC.md` is revised.** Cinemé supports TV series, including anime series, as a second watchlist media type. Still excluded: episode feeds, streaming playback, social features, external anime-order integrations, specials, multi-episode bundles, push notifications and background jobs.
2. **Tonight still recommends exactly ONE thing**: one movie or one episode. An episode recommendation is the **next unwatched regular episode** of a watchlist series, derived from the user's saved progress. Cinemé never picks a random episode and never silently skips ahead.
3. **Media identity is explicit everywhere.** Movies and series have separate tables, separate ids (TMDB movie and TV ids overlap), separate routes and an explicit `media_type`/`kind` field. Existing movie tables, endpoints, history semantics and the `weighted_v1` results for movie-only input are unchanged.
4. **Standard TMDB order, regular seasons only.** Season 0 (specials) is excluded and the limitation is explained in the UI. Anime series use the same model.
5. **Progress is a per-user pointer** ("Last watched: Season 1, Episode 4") that the user can set and correct. Mark watched advances it; Watch Tonight (accept) records intent and never advances it.
6. **A persistent server-side preference** `tonight_media` (`movies` | `movies_and_shows` | `shows`, default `movies`) decides which candidates Tonight considers. It never alters history, watchlist membership or progress, and never silently falls back to another media type.
7. **Series continuity** is a bounded, deterministic additive bonus for the next episode of a series the user recently *confirmed* watching, fading with inactivity (formula in the design). It is a new engine version `weighted_v2` that leaves movie scores bit-identical to `weighted_v1`.
8. **Compatibility is capability-gated.** Clients that do not declare series support keep the current movie-only contract, and the new fields are additive.

## Why

The backlog wants shows and anime in the same "choose one thing" promise. A separate series model keeps the movie evidence, ratings and tests untouched, an explicit progress pointer keeps "next episode" honest, and an additive, versioned engine change keeps determinism and replayability (no randomness, no model).

## Tradeoff

- Large change: new tables, a new engine/config version, a union watchlist, new UI states. It is staged (S1–S6 in the design) so each stage ships independently behind capability gating.
- Order limits: TMDB's standard order is not every viewer's order (anime splits, specials, regional ordering). It is stated in the UI instead of guessed; alternative orders need a later ADR.
- Episode runtime can be unknown. It stays unknown (excluded under a runtime cap, eligible without one) instead of estimated, which can hide some episodes under a cap; the no-match counts say so.
- Old clients cannot show episodes, so they continue to see movies only. That is the single, documented exception to "no silent fallback" and applies only to clients that never asked for shows.

## Affected contracts (updated when implementation is approved, not now)

`PROJECT_SPEC.md` non-goals; `DATA_MODEL.md` (new tables, `user_preferences`, `recommendations`); `API_CONTRACT.md` (series, progress, preference, Today and watchlist additions, capability header); `RECOMMENDATION_ENGINE.md` (`weighted_v2`, continuity, episode filters); `FRONTEND_SPEC.md` (Tonight episode card, media preference, Watchlist filter, add screen, progress).

## Validation (per stage, see the design)

Mocked TMDB adapter fixtures; ownership and isolation; idempotent and concurrent mark-watched and progress correction; union watchlist pagination; engine fixtures including v1/v2 movie regression and continuity examples; capability-gating tests with and without the header; Flutter widget tests for every state; migration up/down on PostgreSQL.
