# ADR 007 — Display-only streaming availability and a streaming region

Status: accepted by the project owner, 2026-10-02 (P4 close-out request).

## Decision

1. **Availability from TMDB watch providers.** `GET /api/v1/movies/{tmdb_id}/availability` returns, for the caller's region, the providers TMDB lists (JustWatch data): `streaming` (subscription/flatrate), `free` (free and ads), `rent` and `buy`, each `{id, name, logo_url}` in TMDB display-priority order, plus TMDB's own watch-page `link`, `fetched_at` and `stale`. Nothing is invented: an absent region or empty TMDB data gives empty lists. Architecture stays Flutter → FastAPI → TMDB; the token never leaves the backend; logos come from the TMDB image CDN like posters, at `w92`, with the same path vetting.
2. **Cache.** One TMDB call (`/movie/{id}/watch/providers`) returns every region; the normalized result is stored on the shared `movies` row (`watch_providers` JSONB, `watch_providers_fetched_at`) and treated as fresh for 24 hours. On a 429/502/503 with older data the old data is served with `stale: true`; without any cache the endpoint fails visibly (503). Availability is shared metadata, not private data, so a GET may refresh it (the documented metadata-cache side effect).
3. **Region.** `users.country_code` (nullable ISO 3166-1 alpha-2, validated against tzdata's `iso3166.tab`) is set with `PATCH /me {country_code}`; null means "derive from the profile timezone" via tzdata's `zone.tab` (e.g. `Asia/Kolkata` → `IN`); `UTC` implies no region and nothing is shown. `GET /me` returns `country_code` and the effective `region`. `GET /api/v1/watch/regions` lists TMDB's provider regions (cached 24 h in process) for the Profile picker.
4. **Display only.** Availability never enters ranking, filters, explanations or the pick; the scorer is unchanged (`weighted_v1`/`weights_v1`). Selection never calls the provider. Tonight shows "Available on" under the film's details (subscription first, free marked, rent/buy as one muted line) with the attribution "Streaming data: JustWatch · <region>". Loading, failure, unknown region or no providers show nothing, so the recommendation is never disturbed. No deep links, no JustWatch scraping or private API.

## Why

The owner asked to show where tonight's film can be watched (India: JioHotstar, Netflix, Prime Video …) without weakening the architecture or the deterministic engine. TMDB's watch-provider endpoint is the licensed source already in use; caching per film avoids N+1 calls and keeps Tonight working during TMDB outages.

## Tradeoff

- Availability can be up to a day old (longer, flagged stale, during outages). The UI says the data comes from JustWatch rather than promising it.
- The region picker is a long list without search; acceptable for a setting changed rarely.
- PROJECT_SPEC listed "streaming availability with regional freshness" as future scope; this brings a display-only subset into V1 and leaves filtering/scoring by availability out of scope.

## Attribution

TMDB's terms require JustWatch attribution whenever watch-provider data is shown; Tonight shows it next to the providers, and README/About keep the TMDB notice.

## Affected contracts

API_CONTRACT (availability, regions, `PATCH /me country_code`, `GET /me region`), DATA_MODEL (`users.country_code`, `movies.watch_providers*`), ARCHITECTURE (TMDB integrations), PROJECT_SPEC (scope), FRONTEND_SPEC (Tonight card, Profile). Migration `0004`.

## Validation

Unit tests for normalization (grouping, priority order, dedupe, invalid entries, logo/link vetting, malformed payload → 502) and the TMDB call shape; PostgreSQL tests for region from timezone vs explicit code, invalid codes, empty data, 24 h cache and refresh, stale fallback and visible failure, one fetch shared across users/regions, and that choosing never calls availability; Flutter tests for provider rendering and the empty/failure states; emulator check with live IN data.
