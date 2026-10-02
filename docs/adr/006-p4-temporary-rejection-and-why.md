# ADR 006 — P4 brings temporary rejection, the pause and a Why drawer forward

Status: accepted by the project owner, 2026-10-02 (P4 scope decision).

## Decision

1. **Temporary rejection moves from P5 into P4.** `POST /api/v1/recommendations/{id}/reject` is implemented for the reasons that need no viewing history or blocks: `not_tonight`, `too_long`, `wrong_genre`, `too_serious`, `want_lighter` and `other`, with `choose_another` selecting ONE replacement atomically, the third-rejection pause, `continue_after_pause` (Continue once) and the 20 attempts/day cap. The `rejection_feedback` table is created in migration `0003` (P4) instead of P5.
2. **Still P5:** `already_watched` and `never_recommend` reasons (they need `viewings` and `movie_blocks`), `POST /recommendations/{id}/watched` (Mark watched), ratings and `GET/DELETE /me/blocks`. The request schema rejects those reasons with 422 until then. The normal app hides Already seen, Never recommend and Mark watched while viewing history does not exist; the preview build keeps showing its scripted versions.
3. **Reason text is rendered and stored by the server.** Each reason object carries a deterministic `text` alongside `code`, `values` and `source` (additive to API_CONTRACT). Text is produced once at selection from fixed templates and stored in `reason_data`, so old cards keep their wording; the app renders it as-is. Reason codes used beyond the documented examples: `tonight_genre_match`, `not_offered_before`, `not_offered_recently`, `tmdb_rating`, `best_remaining_match` and uncertainty `unknown_genres` (all from scoring inputs, never generated prose).
4. **Why drawer.** "Why this film?" on the Tonight card opens a winner-only sheet: all stored reasons/uncertainties plus the component breakdown from `GET /recommendations/{id}` (points per component of its weight, engine/config version). No runners-up, no percentages.
5. **Secondary action label.** The Tonight card's secondary action reads "Not feeling it" (was "Pick another"); it opens the same reason sheet.
6. **Watchlist mutations now return `today`** (completing ADR 004): add clears a cached no-match, removing the current pick supersedes it; neither selects a film.

## Why

Without rejection, P4's real Tonight could only offer one film per day with no honest way to ask for another, and the pause/continue rules (product invariants, FRONTEND_SPEC) could not be exercised against real data. The reasons that create permanent records stay in P5 so P4 does not pull viewings, blocks and ratings forward.

## Tradeoff

A user who has already seen tonight's film can only skip it with "Not feeling this one" until P5; nothing records that they watched it, so it can be offered again on another day. P5 adds Already seen (viewing with unknown date) and the watched exclusion.

## Affected contracts

API_CONTRACT "Recommendation actions and history" (reject reasons in P4, reason `text`), "Watchlist" (`today` in responses); DATA_MODEL "Additive migration schedule" (`rejection_feedback` in P4); DEVELOPMENT_PLAN P4/P5 scope; FRONTEND_SPEC Today card and Why drawer; RECOMMENDATION_ENGINE reason codes.

## Validation

PostgreSQL integration tests for reject/replacement, pause, Continue once, context-change lift, daily cap, detail validation, history/detail/comparison and isolation; Flutter tests for the reason sheet (no Already seen in the normal build), pause and Continue once, Why drawer and the hidden P5 actions; emulator run against the real watchlist.
