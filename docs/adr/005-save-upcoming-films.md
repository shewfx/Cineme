# ADR 005 — Saving upcoming and unknown-date films; Watchlist swipe removal

Status: accepted by the project owner, 2026-10-02 (P3 close-out).

## Decision

1. **Watchlist storage and Tonight eligibility are separate.** Non-adult films with ready metadata can be added whatever their release date: released, upcoming (date after the user's local date) or unknown date. Adult films are still rejected with `422 MOVIE_INELIGIBLE` and never stored (unchanged).
2. `MovieSummary` gains `released: bool` — true only when `release_date` is known and on or before the user's current local date. `can_add` is now false only for adult or unavailable films.
3. Tonight eligibility is unchanged and enforced by the engine in P4: RECOMMENDATION_ENGINE exclusion 1 `movie_unavailable` already covers "unknown release date or release date after user's current local date". P3 stores `release_date` exactly as TMDB normalization gives it (unknown stays null) and computes `released` at read time, so an upcoming film becomes eligible on its release day and an unknown-date film once a metadata refresh establishes a date. No scoring is implemented in P3.
4. Watchlist rows are removed by swiping right (no confirmation dialog) with an immediate Undo, instead of a trailing X button and a confirm dialog. Undo re-adds through `POST /watchlist`, which restores the archived entry (its added date restarts, as documented for restores). A poster-grid layout is available; there, a long-press opens "Remove from watchlist" on the same removal path. The layout choice is a device-local presentation preference (`shared_preferences`), not account data.

## Why

1. Users want to keep films they are waiting for; refusing them pushes that list elsewhere. Eligibility is a ranking-time question about today's date, not a storage question.
2–3. Keeping the raw date and deriving `released` per request avoids a stored flag that goes stale and needs a job to flip.
4. The project owner asked for a faster removal with Undo; Undo makes the dialog unnecessary.

## Tradeoff

- A watchlist can contain films that Tonight will never pick yet; the row and search result say "Not released yet" so a no-match is explainable.
- Undo is a new add request, so it can fail (shown as an error) and resets the entry's added date.
- During a swipe the row slides out before the server confirms; the list itself is still not optimistic — a failed request slides the row back and explains the failure.

## Affected contracts

API_CONTRACT "MovieSummary / MovieDetails" (`released`, `can_add` meaning) and "Watchlist" add validation; DATA_MODEL `movies.release_date` note and the add rule; PROJECT_SPEC Search; FRONTEND_SPEC Watchlist/Search. No schema change, no migration.

## Validation

PostgreSQL integration tests: upcoming and undated films are saved with `released=false` and their date preserved; an undated film becomes `released=true` after a metadata refresh supplies a past date; adult films are rejected and not stored. Unit test for the release gate (today counts as released; unknown never does). Flutter widget tests for swipe threshold/snap-back, swipe removal, Undo, failed-removal restore, in-flight duplicate guard, screen-reader remove action, list/poster toggle and persistence, poster placeholder, small screen with 200% text, and bottom-navigation clearance; the preview fake excludes unreleased films from Tonight.
