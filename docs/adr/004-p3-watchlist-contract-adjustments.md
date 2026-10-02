# ADR 004 — P3 watchlist and movie contract adjustments

Status: accepted by the project owner, 2026-10-02.

## Decision

1. `POST /api/v1/watchlist` and `DELETE /api/v1/watchlist/{entry_id}` return their documented bodies **without** the `today` envelope until Today exists in P4: `{entry, already_present}` and `{removed: true}`. From P4 the `today` field is added (additive change).
2. `PATCH /me/preferences` stays deferred to P4 (as in ADR 003) because its contract response also contains `today`. The P3 plan line "real editable profile/preferences" is therefore partly deferred; `PATCH /me` (P2) covers display name and timezone.
3. `MovieDetails` additionally exposes `original_title`, `vote_average` and `vote_count`, stored in `movies` as DATA_MODEL already specifies. They are display metadata only and never ranking inputs.
4. The TMDB client re-attempts **connection setup** up to three times (HTTPX transport retries) in addition to the one documented request retry. No request has been sent when a connection attempt fails, so this cannot duplicate work.

## Why

1–2. Returning a fabricated or empty Today would misrepresent state that does not exist yet; omitting the field is honest and additive later.
3. The owner asked to preserve these TMDB facts; DATA_MODEL already stores them.
4. On the development network roughly half of new TLS connections to `api.themoviedb.org` were reset (`WinError 10054`) independent of Cinemé. Connection-level retries made 20/20 fresh-connection searches succeed without changing request semantics.

## Tradeoff

Clients built against P3 must tolerate `today` appearing in P4 responses (additive). Worst-case latency for an unreachable TMDB grows slightly but stays inside the 8 s operation budget.

## Affected contracts

API_CONTRACT "Watchlist" and "MovieSummary / MovieDetails"; ARCHITECTURE "Errors, resilience and limits". No DATA_MODEL change.

## Validation

PostgreSQL integration tests for add/list/remove responses; adapter unit tests for normalization and retries; live probe of 20 fresh-connection searches; emulator search/add/remove against live TMDB.
