# Implementation status

Records only verified work. Phases follow [DEVELOPMENT_PLAN.md](../DEVELOPMENT_PLAN.md). Future work: [ROADMAP.md](ROADMAP.md).

## Release and hosted state (verified 2026-10-08)

| Artifact | Version | Evidence |
|---|---|---|
| `main` source, tag `v1.0.3` | 1.0.3+4 | `frontend/pubspec.yaml`, `CHANGELOG.md` |
| Hosted web/PWA | 1.0.3, build 4 | live `/version.json` |
| Last distributed Android APK | **1.0.2, version code 3** | project owner; the APK for 1.0.3+4 has not been distributed |
| Hosted PostgreSQL (Neon) | migration `0006` = repository head | `scripts/migrate_hosted.py` dry run (read-only), PostgreSQL 18.6 |

Version 1.0.3 therefore exists on `main` and the web, but not as a distributed APK; the next distributed APK must carry a version code above 3 (the next planned build, 1.1.0, uses 5 so that 4 stays reserved for 1.0.3).

## v1.1.0 — New-account onboarding (branch `feat/onboarding-v1.1.0`, 2026-10-08)

Implemented, not merged, not deployed. Decision: [ADR 010](adr/010-onboarding-completion.md).

- **Backend:** migration `0007` adds `users.onboarding_completed_at` and backfills every existing user to `created_at`; `GET /me` returns it; `PATCH /me {onboarding_completed:true}` sets it once (one-way, original timestamp kept on retries, `false`/`null` are 422), reusing the users-row lock and idempotency ledger.
- **Flutter:** `/onboarding` gate for accounts whose profile says incomplete (an absent field counts as complete); welcome (“One movie. No scrolling.”) and an add step that reuses the Search panel (add-only), shows a server-derived count with a five-film nudge, and has Skip and Continue. Both complete onboarding; closing the app, signing out or back do not. Continue/Skip with no films ends in Tonight's existing empty-watchlist state. Version `1.1.0+5`.
- **Trending in the add step:** with an empty query the add step shows “Trending this week”, a bounded grid (at most 12) of posters with title, year and an Add action, fed by the new `GET /movies/trending` (TMDB weekly trending through the existing provider, cached in process for an hour, filtered per user for add eligibility; not personalized, never used by Tonight). One selection spans trending and search; failure offers Retry while search, Skip and Continue keep working. ADR 010 amendment.
- **Discovery on the Watchlist add screen:** the same grid with a selector: Trending this week (default), Popular releases this month and Popular releases this year via the new `GET /movies/popular?period=month|year` (TMDB `/discover/movie`, `popularity.desc`, release window up to the caller's local today; popular releases, not trending history). Search and discovery share one server-backed membership; Tonight is unchanged; onboarding keeps weekly trending only. ADR 010 amendment.
- **Not in this release:** follow-up refinements, poster caching, series.

| Check | Result |
|---|---|
| `uv run ruff check .` / `ruff format --check .` / `mypy app` | clean (61 files formatted; 35 source files) |
| `uv run --env-file .env pytest` (local PostgreSQL 16) | 371 passed (includes new: onboarding PATCH/GET, isolation, monotonic timestamp, replay, rejection of `false`/`null`; migration backfill and downgrade; trending bounds, eligibility, per-user filtering, read-only, failure, provider cache and stale copy) |
| `dart format --output=none --set-exit-if-changed lib test` / `flutter analyze` | exit 0 / no issues |
| `flutter test` | 296 passed (includes new: trending grid layout, Add/Added without double submit, shared selection across search, failure/Retry/empty states; welcome, add, five-film nudge, Skip, Continue with an empty list, failed add, duplicate add, resume, failed completion retry, leave-without-completing, back, existing user, account switch, 200 % text, absent/null/malformed field, gate redirects) |

Hosted state before this work (read-only dry run, 2026-10-08): migration `0006` = head. **Migration `0007` has not been applied to the hosted database**, and nothing was deployed. Manual device/browser verification of the new screens was not performed. Rollout order when approved: dry run, `--apply` `0007`, deploy backend, build/deploy web, then the APK `1.1.0+5` (the last distributed APK is 1.0.2, code 3).

## v1.0.2 and v1.0.3 (2026-10-05)

- 1.0.2: new Cinemé logo, red “mé” wordmark and app icons (PRs #12–#13).
- 1.0.3: Profile → About shows installed version/build and source commit; release versioning policy in [RELEASING.md](RELEASING.md) (PR #14).

## Integer star ratings, root-tab swipes and Watchlist artwork

- User ratings are nullable integer stars from 1 to 5 across Flutter, API schemas, PostgreSQL and recommendation learning. The shared selector uses coral filled and muted outlined stars, states the selected value as “N out of 5,” and does not preselect unrated records.
- Migration 0006 explicitly maps Disliked→1, Okay→3, Liked→4, Loved→5; null stays null. The downgrade maps two stars to Disliked because the former categories have no two-star value. Applied to the hosted database (verified 2026-10-08).
- Root tabs respond to horizontal, predominantly horizontal swipes in Tonight → Watchlist → History → Profile order, with no wrap. Nested routes are disabled; row/poster/choice-pill gestures are excluded from tab swiping.
- Watchlist movie details now layers a dynamically loaded, blurred and darkened poster behind the existing details content, fading to the app background before the fixed actions and bottom navigation. Missing posters keep the solid background.
- Verification: see the PR discussion for emulator/Chrome screenshots and the exact test runs; do not describe this change as merged or deployed before review.

| Phase | Status |
|---|---|
| P0 — Bootable repository skeleton | Complete: local gates, manual launch/health and GitHub Actions CI verified; request-ID header implemented in P2 |
| P1a — Context to one movie card (fake data) | Complete: merged to `main` in PR #2 (CI green) |
| P1b — Inventory, history, profile, loading/empty/error (fake data) | Complete: merged to `main` in PR #3 (CI green) |
| P1c — Feedback, replacement, pause, accept vs watched, no match (fake data) | Complete: merged to `main` in PR #4 (CI green) |
| P2 — Auth, profile bootstrap, persistence foundation | Complete: merged to `main` in PR #5 (CI green incl. PostgreSQL); cross-account movie-data isolation deferred to the P3 two-account test |
| P3 — TMDB search and persistent watchlist | Complete: merged to `main` in PR #6 (CI green incl. PostgreSQL); two-account isolation passed (project owner) |
| P4 — Deterministic daily selection (+ ADR 006 rejection/Already watched, ADR 007 availability) | Complete on branch `feat/p4-tonight-recommendations`: all automated gates pass incl. PostgreSQL; emulator flows exercised against the real watchlist; published via PR (see git history). Two-account Tonight isolation on a device not performed (second account's credentials unavailable); covered by automated tests |
| Web/PWA deployment + Tonight/Search/Watchlist UI refinement (not a roadmap phase; ADR 008, ADR 009) | Merged to `main` in PR #8; existing deployment remains live. Physical iPhone Add-to-Home-Screen check and a live first-screen Skip run are still open |
| P5 — Feedback, history, ratings and conservative learning | Complete; merged to `main` in PR #9. Migrations 0005 and 0006 are applied to the hosted database (verified 2026-10-08) |
| P6–P8 | Not started |

## Web/PWA deployment and UI refinement: 2026-10-03, merged in PR #8

Platform task, not a roadmap phase. At the time it was completed P5 had not started. Decisions: [ADR 008](adr/008-tonight-setup-skip-and-watchlist-sort.md), [ADR 009](adr/009-hosted-web-pwa-on-vercel-and-neon.md). Procedure and environment names: [DEPLOYMENT.md](DEPLOYMENT.md).

### What exists

- Flutter web target and PWA shell (manifest, Cinemé icons generated from the app's own palette and Jost, iOS standalone metadata, a viewport tag identical to the engine's, charcoal splash); a centred 480 px canvas on wide windows; browser session storage on web; `API_BASE_URL=same-origin`.
- Backend: serverless/pooler engine mode, TLS required for production database URLs, Vercel entrypoint, explicit `scripts/migrate_hosted.py`; CI builds the web bundle and scans it for server-side secrets (`infra/check_web_bundle.py`).
- Hosted: one Vercel project (Hobby) + Neon (Free), Supabase Auth, TMDB. Hosted database brought to `0004` at first deployment; later migrations were applied afterwards (see Release and hosted state).
- UI refinement: Tonight startup (“Tonight’s the night.”), compact selectors on the first Tonight screen and Edit tonight, Skip, just pick something (explicit Surprise me); Search rows without runtime placeholder and with a 76x114 anchoring poster; Watchlist Sort (server-side `sort` on `GET /api/v1/watchlist`).

### Verified (local gates)

| Check | Result |
|---|---|
| `uv run ruff check .` / `ruff format --check .` / `mypy app` | clean (51 files formatted; 30 source files) |
| `uv run --env-file .env pytest` (PostgreSQL) | 330 passed |
| `dart format --output=none --set-exit-if-changed lib test` / `flutter analyze` | exit 0 / no issues |
| `flutter test` | 184 passed |
| `flutter build web --release` (same-origin config) + `infra/check_web_bundle.py` | built; no secrets found (22 text files scanned) |
| `docker compose ... config --quiet` | unchanged definition (CI validates it) |

### Verified live on https://cineme-theta.vercel.app (throwaway account, headless Chrome at 390x844, 320 and 1440 wide)

| Check | Result |
|---|---|
| `/healthz`, `/readyz` (DB at head through the pooler), `/api/v1/*` unauthenticated | ok, ready, 401 envelope with `Cache-Control: no-store`; `/docs`, `/openapi.json` 404 |
| Sign-in, bootstrap, reload, full browser restart | signed in; session survived both; sign-out cleared storage; sign back in worked |
| Revoked/expired refresh token | the app shows its “Couldn't finish signing in” screen with Retry and Sign out; Sign out recovers |
| TMDB search, add, remove, posters, availability | real results; real posters in the Flutter build; “Available on” shown for the pick |
| Tonight: pick, reload (same film), Why, comparison, Not tonight (replacement), Already watched (recorded), third pass pauses, Continue once, Watch Tonight | all behaved as on Android; one film at a time |
| Watchlist sort on Neon | all 8 modes correct; paging two at a time equals the full list; invalid sort 422; sort and layout choice survive a reload |
| New UI on the live bundle | opening, Edit tonight selectors, sort sheet, poster grid and Search rows shown as designed; bundle contains the new strings and not “Runtime unknown until added” |
| Layout | 390 px phone view matches the Android app; 1440 px desktop is a centred canvas; 320 px renders cleanly |

### Tonight hero and provider investigation (2026-10-03)

- **Provider investigation (before any change):** cause was **region resolution**. 4 of 5 hosted accounts had no streaming region (UTC profile implies none) so the section was hidden with no explanation. TMDB data, the per-film cache (regions selected at read), serialization (`flatrate` to `streaming`) and rendering were correct; the hosted cache matched live TMDB for IN (Spirited Away: Netflix; The Grand Budapest Hotel: JioHotstar; Paddington 2: rent/buy only; Alien: no IN entry; Inception: Prime Video and JioHotstar). Fix: a quiet “Choose your streaming region” link on the card when the region is unknown; heading renamed “Where to watch”.
- **Hero:** blurred, dimmed artwork with a sharp 2:3 poster card in front, about 60% of the screen height on a phone (60% on 390x844 with safe areas; smaller on short screens and at large text), details centred below, compact pinned action bar. Flutter: 195 tests pass (format and analyze clean), including hero geometry at iPhone, 360x640, 320 px at 200% text and desktop canvas widths.

### Final UI refinements (2026-10-03)

- **iPhone touch offset:** root cause was the page's viewport tag. `index.html` asked for the full-screen cover fit; Flutter web rewrites the tag at startup (to `width=device-width, initial-scale=1.0, maximum-scale=5.0`, no cover fit) and does not read iOS safe-area insets. On iOS that flipped the viewport geometry after the engine's first measurement without a resize event, so painted and touch positions disagreed until a resize (Search and the keyboard) re-measured. Fix: declare exactly the engine's tag from the start; a build check keeps it that way. Evidence: the mutation log in Chrome showed the tag changing four events into startup; browser-level sweeps show Flutter laying out with zero insets (so forcing the cover fit would have put the nav under the home indicator). **Not verified on a physical iPhone or in the installed PWA** (no device here); Chrome mobile emulation cannot reproduce iOS viewport behaviour.
- **Floating nav:** 28 px side inset, 20 px above the bottom edge, rounded pill with hairline and shadow, real layout (no transforms); sheets now open over it (root navigator). Tonight reasons removed from the card (Why sheet only); JustWatch attribution behind an info icon; hero capped at 530 px on tall desktop windows; hero ends on a whole pixel (a fractional edge painted a faint line of the blurred artwork).

### Not verified / open

- **Physical iPhone** Add to Home Screen was not tested (no device here). Steps are in DEPLOYMENT.md.
- **Live first-screen Skip**: the throwaway account already had today's pick, and the hosted database holds other users, so its sessions were not reset. Skip is covered by Flutter widget tests, a real-repository request-body test and the preview build; run it on a fresh day or a new account.
- Android: `flutter build apk --debug` succeeds (after the Kotlin workaround in TOOLING.md for this machine's split-drive caches). An emulator/device run was not repeated for this task; Android-specific code paths are unchanged apart from `kIsWeb` branches.
- Tonight refinements (display only; no ranking, session or migration change): TMDB community rating shown as a small gold star and one-decimal value after the runtime (omitted when unknown, never 0.0). `vote_average` is now a nullable field on `MovieSummary` (additive; search leaves it null, Today/watchlist/history carry the cached TMDB value); Flutter never calls TMDB. The bottom nav is a custom `FloatingNavBar`: a compact, constant-width capsule (min(available - 56, 316) px, centred) of four icon-only tabs with even spacing; the selected tab is a coral pill around its icon only, never expanding. 48 px targets, tooltips and semantic labels kept, plain layout (no transforms). The foreground poster has a restrained hover/touch tilt (`PosterTilt`: <=1 degree, 2.5 px lift, +0.8% scale, 7% glint); touches that begin on the poster are claimed so the page does not scroll, touches elsewhere scroll; release/cancel/exit return to rest; reduced motion disables it.
- The previous Chrome typing run showed a harmless `null.toString` page error while typing into a field under automation; it was not reproduced by manual input and did not affect sign-in.

### Known limits

Runtime database role is the Neon owner; free-tier compute suspends when idle; function region `iad1` (US) for a Neon database in `us-east-1`; the hosted API has no CORS middleware by design (same-origin only).

## Watchlist movie details and scroll-depth hint — 2026-10-04

### Delivered

- Watchlist poster and row taps open `/movies/:tmdbId` inside the Watchlist shell. Details load on demand through the existing authenticated `GET /api/v1/movies/{tmdb_id}` endpoint; no backend or database changes were required.
- The detail screen shows available title, release, runtime, genre, TMDB rating, overview and regional availability facts. It reuses Tonight's `AvailabilitySection`, including provider priority, three visible providers, expansion, region, attribution and the separate rent/buy line.
- Remove uses Watchlist removal with Undo. Mark watched uses the existing manual viewing endpoint and updates History/Watchlist/Today state. Never recommend uses the existing reversible per-user block endpoint and leaves Watchlist membership unchanged.
- `ScrollDepthHint` is shared by Movie Details and Tonight. It tracks remaining vertical extent, fades near the end, hides when content fits or reaches the end, ignores pointer input, and disables its fade under reduced motion.

### Verification

- Full Flutter suite: 259 passed. `flutter analyze` reports no issues; Dart format check changed 0 files. Flutter web release build succeeded and the bundle scan found no server-side secrets (22 text files scanned).
- Backend was unchanged; no backend tests or hosted database operations were needed.

### Manual checks remaining

- A physical iPhone walkthrough of details/provider expansion, action flows, scroll glow, and Tonight poster tilt/taps remains required. No physical device was available for this pass.

## P5 — Feedback, history, ratings and conservative learning

Implemented on `feat/p5-history-ratings`, merged in PR #9. This milestone keeps Today to one recommendation and does not apply migration 0005 or deploy changes.

### Delivered

- Durable follow-up state on accepted recommendations. GET Today surfaces only the most recent unresolved accepted pick from an earlier user-local date. `not_yet` suppresses it for that date; `yes` records one viewing and resolves it; `no` resolves without recording a viewing. Missed days do not lose the prompt.
- One canonical viewing write path for direct Already watched, History logging, recommendation completion and follow-up confirmation. It preserves unknown dates, accepts an optional past date/rating, archives active watchlist inventory, prevents duplicate user/movie history rows, and returns idempotent response bodies.
- History reads watched records and recommendation history with cursor pagination and user ownership. Ratings were originally the four categories `loved`, `liked`, `okay`, `disliked` (replaced by integer 1–5 stars in migration 0006, see the top section); edits are versioned replacements and rated genre evidence feeds the existing deterministic affinity component without changing `weighted_v1` weights.
- Persistent per-user Never recommend blocks, hard-filter integration, reversible profile management, and block pagination. Temporary rejection, removal and ratings do not create blocks.
- Flutter real-build repositories and UI for History, search-only manual logging, rating edits, follow-up choices, watchlist Mark watched and blocked-film restoration.

### Verified

| Check | Result |
|---|---|
| Backend PostgreSQL suite | 345 passed, including empty upgrade/downgrade/upgrade and P5 ownership, idempotency, rating, follow-up and block checks |
| `flutter analyze` | No issues found |
| `flutter test` | 245 passed |

### Not performed

- (At the time of PR #9) migration 0005 was not applied to hosted PostgreSQL. It has since been applied; see Release and hosted state.
- Physical device checks for the new P5 screens remain open. The web deployment's physical iPhone check also remains open.

## P4 — 2026-10-02, branch `feat/p4-tonight-recommendations`

Real Tonight: one deterministic pick from the caller's own watchlist, explained, stable across reloads, with temporary rejection and the pause brought forward by [ADR 006](adr/006-p4-temporary-rejection-and-why.md). Already seen, Never recommend, Mark watched, ratings and blocks stay P5.

**Backend**
- Engine `weighted_v1` / config `weights_v1` (`app/recommendations/engine.py`, `weights_v1.json`): pure `rank(RankingInput, EngineConfig)`, Decimal precision 28 HALF_EVEN, `score = 35G + 30C + 10D + 10A + 10R + 5Q`, filters in documented precedence (`movie_unavailable` incl. unknown/future release date, `already_watched`, `movie_blocked`, `offered_this_session`, `genre_blocked`, `runtime_unknown`, `runtime_exceeded`), tie-break total desc → added_at asc → tmdb_id asc, reason codes plus uncertainties. Config validated (exact keys, ranges, weights sum 100) and hashed (SHA-256 of canonical JSON). No network, database, clock or randomness.
- Migration `0003`: `recommendation_sessions` (unique user/local date, timezone snapshot, DST-aware `day_ends_at`, JSONB context, version, deferred circular pointer), `recommendations` (one row per attempt incl. no-match; checks for selected/no-match shape, score range, ≤9 runners-up, resolved/accepted timestamps; partial unique index = at most one offered/accepted per session) and `rejection_feedback` (ADR 006). No candidate-score table; evidence ≤64 KiB with trailing runners-up dropped first.
- Endpoints: `GET /today` (read-only), `PATCH /today/context`, `POST /today/choose`, `POST /recommendations/{id}/accept`, `POST /recommendations/{id}/reject`, `GET /recommendations`, `GET /recommendations/{id}`, `GET /recommendations/{id}/comparison`, `GET`/`PATCH /me/preferences`; `POST`/`DELETE /watchlist` now return `today`. All mutations: users-row lock, P2 idempotency ledger, `expected_session_version` (409 `VERSION_CONFLICT` with current version), no network inside the lock. States derived per API_CONTRACT precedence; reload never selects. Pause after 3 rejections (`CONTEXT_REVIEW_REQUIRED` unless Continue once or a real scoring change; mood-only edits don't count), 20 attempts/day (`DAILY_ATTEMPT_LIMIT`), `SESSION_EXPIRED` for another day's pick, `INVALID_TRANSITION` for non-current picks. Profile cap/blocked genres combine as minimum/union with `overridden_fields`. Invalidation: scoring-context or recommendation-affecting preference edits supersede the open pick; removing the picked film supersedes it; adding a film clears a cached no-match.

**Flutter**
- `ApiTodayRepository` + DTOs replace the normal-build placeholder; Today reloads per user and when the watchlist changes. Context-first flow, ONE card, "Not feeling it" reason sheet (no Already seen in the normal build), pause/Continue once/Stop, accept ("Tonight's plan", Change my mind), no-match with counts, empty watchlist → Add movies. Server-rendered reason text; "Why this film?" winner-only drawer with component points and engine/config version. Stale version/expired day reload Today and say so. Already seen, Never recommend and Mark watched hidden until P5. Preview build unchanged apart from the shared label and Why (no scores in the fake).
- Search rows (owner request): poster | details | compact Add / In watchlist centred on the poster, "Not released yet" in the details, stacked action at large text.

### Verified

| Check | Result |
|---|---|
| `uv run ruff check .` / `ruff format --check .` / `mypy app` | All passed (27 source files) |
| `uv run pytest` (local PostgreSQL 16) | 263 passed: 57 engine unit tests (worked examples 74.333333 / 61.681818, relax swap 67.272727 / 64.833333, no-trait baseline 64.833333 / 55.000000, every filter and its precedence, cap equality, release day, intent matrix, pace/trait boundaries, rating shrinkage and edit replacement, Jaccard, floor-day saturation, vote shrinkage, ties, shuffled input, metamorphic unrelated candidate, 500 candidates, invalid configs, no network/clock imports) + 36 Today integration tests (read-only GET, context required, first pick and reload stability, mood-only keep, 4 parallel chooses → one pick, replay/conflict, stale version, unreleased/undated/unknown-runtime filters, cap never relaxed, avoided genres, reject + one replacement, no same-day re-offer, too_long/wrong_genre/want_lighter effects and validation, pause/Continue once/context lift, daily cap, context patch no-op/mood/scoring, accept no-op/persistence/no history, isolation 404s, timezone rollover and SESSION_EXPIRED, day end, preference invalidation and minimum cap, watchlist invalidation, history/detail/comparison, ≤9 runners-up, 500-film round trip, identical state → identical pick) + migration up/down/up incl. 0003→0002→head + all P0–P3 tests |
| Large watchlist | 500 synthetic films: `POST /today/choose` round trip 111–123 ms locally (TestClient + PostgreSQL 16, one grouped offer-history query, no TMDB calls); pure ranking of 500 candidates well under the 2 s test bound |
| `dart format` / `flutter analyze` | 0 changed / No issues found |
| `flutter test` | 110 passed (+20 real Tonight over a fake Today API: wire format and versions, conflicts, context-first single film, reopen without re-choose, Why drawer, single accept on double tap, three reasons and Too long/Different genre details, pause + Continue once, Stop, no match, empty watchlist, backend/auth failure, stale version message, account switch reload, 360x640 at 200%, preview keeps fakes; +4 search-row layout tests) |
| `docker compose -f infra/compose.yaml config --quiet` | OK |
| APK scan | No TMDB token, TMDB API host, variable name, database URL or Supabase secret/service-role key (only library doc text) |

### Manual emulator run (project owner's real account, 36 → 37 films, normal build)

1–5. Keep me hooked + Under 2 hours → ONE film: Léon: The Professional (111 min) with "111 minutes, within your 119-minute limit." and "Its genre (Crime) fits your “Keep me hooked” choice."
6. Force-stop and reopen → same film, no new attempt.
7. Why → reasons plus G 17.5/35, C 24.0/30, D 5.0/10, A 0.0/10, R 10.0/10, Q 4.1/5, weighted_v1 · weights_v1 (consistent: no preferences/history yet, added today, never offered).
8–11. Not feeling it → Not feeling this one → Show another → Kill Bill: Vol. 1; Léon not returned.
12. Two more passes (→ My Fault) → "That's 3 passes tonight" with Adjust / Continue once / Stop.
14. Continue once → exactly one film (Tetris, 118 min).
13. Edit tonight → Make me laugh → Crazy, Stupid, Love. (Comedy).
15–16. Watch Tonight → "Tonight's plan"; force-stop/reopen → still accepted; no Mark watched (P5).
Accepted-pick replacement asked "Replace tonight's plan?" before changing context to Up to 90 min → Not Another Teen Movie (89 min).
17–18. Pass on it (4th pass pauses again; Continue once) → "Nothing in your watchlist fits tonight — Of the 37 films in your watchlist: 1 not released yet, 6 already offered tonight, 30 longer than your time limit." No relaxing of the cap.
19. Avengers: Secret Wars (2027) added from Search ("Not released yet") and counted as not released; never selected.
20. Watchlist list/poster views and Search add still work; state survived an API restart plus app restart.

### Close-out additions (2026-10-02)

- **Already watched** inside Not feeling it (ADR 006 amendment): migration `0004` creates `viewings` (DATA_MODEL shape); the reason records a past viewing (date null unless a past one is supplied, no rating, no recommendation link, never tonight's completion), archives the watchlist entry, counts as a rejection, and selects a replacement only on Show another. Viewed films are excluded thereafter; re-adding returns `409 MOVIE_ALREADY_WATCHED`; D uses viewing genre snapshots as specified; preferences untouched.
- **Streaming availability** (ADR 007): `GET /movies/{id}/availability` (JustWatch data via TMDB, 24 h cache on the movie row, stale fallback, visible failure without cache), `GET /watch/regions`, `PATCH /me country_code` with timezone-derived default. Tonight's "Available on" section (subscription first, free marked, rent/buy muted, JustWatch attribution); nothing shown when unknown/empty/failing. Display-only: no scoring effect, no call during selection.
- **Edit tonight selectors**: three compact fields opening bottom-sheet lists (current value checked, closes on choice, mood/time clearable); Save and Pick with this context unchanged.
- **Idempotent retries**: `RetryKeys` keeps a command's key after an ambiguous failure (no response/timeout/5xx) so retrying the same command is replayed by the server; success or 4xx settles it. Used by Today, watchlist and region mutations.
- Search rows (separate commit), "pass N tonight" wording, and a mojibake fix in one watchlist error message.

### Final gates

| Check | Result |
|---|---|
| `ruff check` / `ruff format --check` / `mypy app` | All passed (30 source files) |
| `pytest` (PostgreSQL 16) | 286 passed (+23 since the first P4 run: 13 availability incl. normalization/region/cache/stale/failure/shared cache/no scoring call, 5 Already watched/replay/privacy, migration table set) |
| 500-film watchlist | `POST /today/choose` round trip 100 ms locally after adding the viewing-history query (was 111–123 ms) |
| `dart format` / `flutter analyze` / `flutter test` | 0 changed / no issues / 118 passed (+8: selectors restore/clear/200%, Already watched path, provider rendering, empty/failure states, same-key retry and replay, settled keys and visible conflicts, single accept after a lost response) |
| `docker compose ... config --quiet` | OK |

### Manual emulator run 2 (normal build, real account, 227-film watchlist)

- Profile → Streaming region sheet listed TMDB's regions; chose India → "IN".
- Tonight (existing accepted Bugonia): "Available on JioHotstar", "Also to rent or buy on Apple TV Store, Zee5, Amazon Video", "Streaming data: JustWatch · IN" — identical to the cached TMDB data for IN.
- Edit tonight: three selectors restored Make me laugh / Okay / Any length; mood sheet checked "Okay"; choosing "Not set" closed the sheet; Save kept the accepted film (mood-only). Keep me hooked + Under 2 hours + Pick with this context asked "Replace tonight's plan?", then picked The Imitation Game (113 min) with rent/buy-only availability (no fabricated streaming).
- Not feeling it → Already watched (sheet text: date unknown, not tonight's movie) → Stop for tonight: database shows one viewing (source already_watched, watched_at null, rating null, recommendation_id null), watchlist entry archived, session not completed; no auto-pick (paused, as passes ≥ 3).
- Continue once → exactly one film (The Mask, 101 min), stable across restart; Why showed G 17.5, C 24.0, D 10.0 (new viewing shares no genre), A 0.0, R 10.0, Q 3.5; Watch Tonight persisted across restart.
- Not re-run this round: no-match (17 films ≤ 90 min make it impractical on the real list; verified in run 1 and by tests) and provider failure on device (covered by tests).

### Known limits / deferred

- Two-account Tonight isolation was not performed on a device (no credentials for the second account); automated coverage: `test_old_or_foreign_recommendations_cannot_be_acted_on`, `test_viewings_are_private`, `test_deterministic_pick_for_identical_state`, Flutter account-switch tests.
- P5: Never recommend/blocks, Mark watched, ratings and learning from them, manual viewings, History UI, `GET /recommendations` UI.
- The region list has no search field; availability can be up to 24 h old.
- Backlog (not P4): local bounded poster-thumbnail disk cache (TMDB poster path stays the source of truth; expiry/eviction; refetch corrupted or missing files; never unbounded).

## P3 — 2026-10-02, branch `feat/p3-tmdb-watchlist`

Flutter → FastAPI → TMDB and Flutter → FastAPI → PostgreSQL. No recommendation, scoring or Tonight selection (P4). Contract adjustments in [ADR 004](adr/004-p3-watchlist-contract-adjustments.md) (accepted) and [ADR 005](adr/005-save-upcoming-films.md) (saving upcoming films; swipe removal).

**Backend**
- Migration `0002`: `movies` (shared TMDB metadata cache keyed by `tmdb_id`; checks on runtime 1..600, votes, relative poster path, status, non-blank title) and `watchlist_entries` (per user, unique `(user_id, movie_id)` incl. archived rows, status/`removed_at` consistency, `source_type` `manual`, keyset index). Metadata refreshes never touch entries.
- `TMDB_READ_ACCESS_TOKEN` required at startup (no fake-results fallback). `MovieMetadataProvider` interface; `TmdbProvider` (HTTPX, bearer, connect 3 s / read 5 s, 8 s budget, one request retry for transient failures, connection-setup retries, 429 → `RATE_LIMITED` with bounded Retry-After, 404, malformed → 502, outage → 503, error-class logging without URLs or tokens). Genre registry and image configuration cached 24 h with a safe poster-base fallback.
- Normalization into Cinemé shapes: runtime 0 → null, empty or invalid date → null, unvetted poster paths dropped, items without id or title skipped, votes range-checked, original title null when equal to title. No raw TMDB JSON stored or returned.
- Endpoints: `GET /api/v1/movies/search` (runtime only from cache; `can_add` false only for adult/unavailable; `released` true only for a known date on or before the user's local date), `GET /api/v1/movies/{tmdb_id}` (7-day cache, stale fallback during outages, adult films never stored), `GET /api/v1/genres`, `GET /api/v1/watchlist` (newest first, cursor, `q` with escaped LIKE, works while TMDB is down), `POST /api/v1/watchlist` (details fetched outside the lock, idempotency preflight and recheck under the users-row lock, 201 new/restored with reset age, 200 already present, 422 `MOVIE_INELIGIBLE` for adult films; upcoming and unknown-date films are saved with `released=false` and their date preserved for P4's `movie_unavailable` exclusion, 409 `WATCHLIST_LIMIT` at 500 active), `DELETE /api/v1/watchlist/{entry_id}` (archives; another user's or unknown id → 404). Mutations use the P2 idempotency ledger. Watchlist changes never modify preferences.

**Flutter**
- Normal build: `ApiSearchRepository` and `ApiWatchlistRepository` behind the existing interfaces (UUID v4 idempotency key per deliberate add/remove; documented outcomes → `InventoryConflict`; malformed data → visible error). Search keeps debounce, 2-character minimum, stale-response guard and its states. Posters load from the TMDB image CDN with the same-size placeholder while loading, on failure or when missing. "Already watched" is hidden until viewing history exists (P5). The watchlist reloads per signed-in user. Watchlist: swipe a row right to remove (threshold with snap-back, no dialog, in-flight guard, failure restores the row) with an Undo snack bar; screen-reader Remove action; List/Poster toggle (3-column 2:3 grid, 2 columns when very narrow, titles only, long-press → Remove) remembered on the device via `shared_preferences` (promoted from transitive to direct, same locked 2.5.5); the last row/tile scrolls clear of the navigation bar and system insets; pagination triggers lazily from the last item in both layouts. Search and rows label upcoming/undated films “Not released yet”.
- Preview build unchanged: fakes only, never builds an API client or contacts Supabase/FastAPI/PostgreSQL/TMDB.

### Verified

| Check | Result |
|---|---|
| `uv run ruff check .` / `ruff format --check .` / `mypy app` | All passed (33 files formatted; 21 source files) |
| `uv run pytest` (local PostgreSQL 16) | 169 passed after the ADR 005 change (was 167): 86 unit (incl. 40 TMDB adapter: normalization of partial/malformed data, retries, timeouts, budget, 429/404/401/5xx, malformed payloads, caches, poster vetting, token never in errors) + 81 integration (incl. 42 P3: search shapes and unknowns, `can_add`, cached runtime, missing poster, validation, upstream failure, auth/profile required, details cache and stale fallback, add/duplicate/list/pagination/filter/remove/restore, ineligible films not saved, outage saves nothing, list during outage, 500 cap, preferences untouched, metadata refresh keeps entries, two-user isolation incl. 404 for another user's entry, no client owner, auth required, idempotency replay/conflict/remove replay, parallel duplicate adds, 10 database constraints, migration table set) |
| `dart format` / `flutter analyze` | 0 changed / No issues found |
| `flutter test` | 86 passed after the Watchlist UX/ADR 005 work (64 earlier + 22 P3; first 9: real repositories over a fake Cinemé API, add/duplicate/remove reflecting server state, network poster vs placeholder, backend failure with Retry, auth failure, account switch without leaks, preview isolation; then 13 replacing the old confirm-dialog test: swipe snap-back below threshold, swipe removal without dialog + Undo, failed swipe restores the row, in-flight duplicate remove ignored, screen-reader Remove action, List/Poster toggle persisted across restart, poster placeholder at 2:3, poster long-press removal + Undo and no grid swipe, nav-bar clearance and 360x640 + 200% text + gesture inset in both layouts, 2-column grid when narrow, unreleased film saved but never picked in preview) |
| Live TMDB adapter | Ambiguous "Arrival" search shows six titles disambiguated by year; details give runtime 116 and genre names; unknown id → 404; 20/20 fresh-connection searches after the connection-retry fix |
| Emulator, normal build, project owner's restored session (single account) | Search shows TMDB posters and years; poster-less 1986 entry shows the placeholder; add → "In watchlist"; duplicate add → "already in your watchlist"; list persisted across an app restart **and** a backend restart; remove persisted across an app restart (verified before the swipe redesign); rows archived, not deleted; no TMDB token, API host or variable name anywhere in the APK |

### Two-account isolation (project owner, 2026-10-02)

Passed, as reported by the project owner: a film added to account A's watchlist did not appear in account B's. This also closes the P2 deferred cross-account check. Automated coverage of the same rule: `test_users_never_see_or_change_each_others_watchlists` (PostgreSQL) and the Flutter account-switch test.

### Final gates (2026-10-02, after ADR 005 and the Watchlist UX changes)

`ruff check` passed; `ruff format --check` 33 files formatted; `mypy app` no issues in 21 files; `pytest` 169 passed (PostgreSQL 16); `docker compose -f infra/compose.yaml config --quiet` exit 0; `dart format` 0 changed; `flutter analyze` no issues; `flutter test` 86 passed. Secret scan of changed/new files: nothing found; no generated files untracked. Not yet verified on the device: swipe removal, poster view and bottom-nav clearance (APK and running API predate these changes).

### Deferred / risks

- Explicit `POST /movies/{id}/refresh`, the in-process rate limiter (60 reads/min, 30 writes/min per subject), the OpenAPI contract snapshot, source-adapter interface, and preference editing (`PATCH /me/preferences`, needs Today; ADR 004).
- TMDB logo asset in About: only the text notice is shown; add the approved logo before release.
- An ambiguous network timeout on add or remove makes a new key on the next tap; same-key retry UI comes with the P4 command flows.
- Development network resets TMDB connections intermittently (TOOLING).

## P2 — 2026-10-02, branch `feat/p2-backend-auth`

P2a, P2b and P2c delivered together (authorized as one task). Scope change: `PATCH /me` and the idempotency ledger brought forward from P3 ([ADR 003](adr/003-patch-me-and-idempotency-in-p2.md)); preference editing stays P3/P4. Password recovery deferred (release gate, as planned).

**Backend**
- SQLAlchemy 2.1 + psycopg 3.3 (sync), bounded pool, statement/lock timeouts 5 s / 2 s; one request-scoped session; services own transactions.
- Alembic 1.20, migration `0001`: schema `cineme` with `users`, `user_preferences` (DATA_MODEL columns, defaults and CHECKs) and `idempotency_records`; revokes schema access from PUBLIC and, when present, Supabase `anon`/`authenticated`. Reversible.
- `GET /readyz`: DB query plus Alembic head check (503 `not_ready` otherwise). `/healthz` unchanged.
- Error envelope for every non-2xx including validation and unexpected 500s; `X-Request-ID` validated or generated and returned on every response (closes the item tracked since P0).
- Token verification with PyJWT 2.15: ES256 only, JWKS from the configured project (5-minute cache, one refresh for an unknown `kid`, 2 s timeout), exact issuer, audience `authenticated`, required `exp/iat/sub/aud/iss`, 30 s leeway, UUID `sub`, signed email, role `authenticated`, no anonymous users. Outage → 503, invalid → 401. No auth bypass: tests inject real keys.
- `POST /api/v1/me/bootstrap`: first call confirms the user with Supabase `GET /auth/v1/user` outside any DB transaction (403 `EMAIL_NOT_VERIFIED`, 503 on outage), then insert-on-conflict for user and preferences in one transaction; 201 created / 200 reused, never resets fields.
- `GET /api/v1/me`: read-only; 409 `PROFILE_NOT_INITIALIZED` before bootstrap.
- `PATCH /api/v1/me` (ADR 003): display name and IANA timezone (tzdata), unknown fields 422, users-row lock, UUID `Idempotency-Key` (400 `IDEMPOTENCY_KEY_REQUIRED`), replay / 409 `IDEMPOTENCY_CONFLICT`, response stored in the same transaction.
- Settings now require `DATABASE_URL`, `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_JWT_ISSUER` (must equal the project URL + `/auth/v1`).
- CI backend job gets a PostgreSQL 16 service so integration and migration tests run there.

**Flutter**
- `supabase_flutter` 2.18 (sign-up, sign-in, session restore, refresh, sign-out) with session persistence in `flutter_secure_storage` 11.2; `dio` 5.11 in one `ApiClient` (bearer per request, envelope → `ApiError`, malformed responses are errors).
- Auth gate and go_router redirects: Sign in / Create account / Check your email / setting-up (Retry, keeps the session) / config-missing. The private shell renders only after `POST /me/bootstrap` then `GET /me`.
- Profile reads `GET /me` in normal builds, shows the signed-in email and Sign out; profile data is keyed to the signed-in user so sign-out and account switches never show the previous user's data. Blocked films show "Coming later" (blocks are P5).
- Normal builds without `--dart-define` configuration show "This build is not configured"; Tonight/Watchlist/History still say "not available in this build yet". Preview build unchanged and never initializes Supabase.
- Android: INTERNET permission for release; cleartext HTTP to the local API allowed in debug builds only.

### Verified

| Check | Result |
|---|---|
| `uv run ruff check .` / `ruff format --check .` | All checks passed / 19 files formatted |
| `uv run mypy app` | No issues in 12 source files |
| `uv run pytest` (TEST_DATABASE_URL → local PostgreSQL 16) | 85 passed: 45 unit (settings, envelope/request IDs, readyz without DB, JWT claims/forgery/algorithms/leeway/outage/rotation, provider get-user outcomes) + 40 integration (migration up/down/up, exact table set, PUBLIC has no schema access, defaults, CHECK/FK/cascade constraints, bootstrap create/reuse/no reset, unverified email, provider outage, 8 concurrent bootstraps converge, GET read-only and 409, missing/invalid/expired/forged tokens, two-user isolation and no client user id, PATCH validation, idempotency replay/conflict/per-user/failed-not-cached/concurrent) |
| `dart format` / `flutter analyze` | 0 changed / No issues found |
| `flutter test` | 64 passed (49 P1 + 15 P2: routing signed out, sign-in → bootstrap → GET /me → shell, sign-in failure, restored session, setup failure with Retry keeping the session, unconfirmed email, sign-up confirmation, sign-out and account switch without leaks, unconfigured normal build, preview isolation, ApiClient bearer/idempotency header/envelope/malformed, profile JSON validation) |
| `docker compose --env-file infra/.env -f infra/compose.yaml config --quiet` | exit 0 |
| Manual: Alembic CLI on the dev DB | `alembic current` → `0001 (head)` |
| Manual: API with the real Supabase project config | `/healthz` ok, `/readyz` ready, `/api/v1/me` without token 401 `AUTH_REQUIRED`, malformed token 401 `TOKEN_INVALID`; project JWKS publishes one ES256 P-256 key |
| Manual: Android emulator, normal build | Supabase initialised; app opened on Sign in (no shell, no preview data); a wrong password reached Supabase and showed "Email or password is incorrect." |

### Manual verification by the project owner (2026-10-02)

| Check | Result |
|---|---|
| Real Supabase account signs in on the emulator | Passed |
| Session is kept when backend setup fails (FastAPI not running) | Passed: setup screen with Retry, still signed in |
| Retry after starting FastAPI completes bootstrap and opens the authenticated shell | Passed |
| Backend reachable at the configured emulator URL (`http://10.0.2.2:8000`) | Passed |
| `/healthz` and `/readyz` | Passed |
| Cross-account movie-data isolation (A's data absent for B) | **Deferred, not passed**: P2 has no user-owned movie data. Moved to the first P3 watchlist manual test. Profile-level isolation is covered by the automated two-user integration tests. |

### Remaining

- The PostgreSQL CI job is verified when this branch's PR runs.
- Least-privilege runtime role vs. migration role: local dev uses the compose superuser for both; dedicated roles and grants belong to deployment.
- Password recovery/reset, profile-edit UI (PATCH /me is API-only), timezone picker, `PATCH /me/preferences`, blocks API: later phases.
- Environment: Flutter must be invoked through the SDK short path (space in the SDK path breaks a native-assets hook); see TOOLING.

## P1c — 2026-10-02, branch `feat/p1c-feedback`

The preview store now models one daily session with all documented Today states (`not_started`, `ready`, `offered`, `accepted`, `completed`, `paused`, `no_match`, `empty_watchlist`) in API_CONTRACT precedence, behind the same `TodayRepository` boundary (`choose` with `continueAfterPause`, `saveContext`, `accept`, `reject`, `markWatched`; `HistoryRepository.rateViewing`; `ProfileRepository.unblock`).

- **Watch Tonight** = accept (intention; no viewing, film stays in the watchlist). **Mark watched** = completion (viewing with date, archives the film, day completed; further choose/save → `TODAY_COMPLETED`). **Rating** is separate, optional and replaces the single observation.
- **Pick another** sheet with the documented reasons (both skips → `not_tonight`; Too long with optional lower cap that must be below the current cap; Something lighter → Relaxing + heaviness target; Different genre needs ≥1 of the film's genres; Already seen). Show another selects exactly ONE replacement; Stop for tonight selects none.
- **Already seen** (card or sheet) records a past viewing with unknown date, never tonight's completion. **Never recommend** sits under More actions and is a reversible block (Unblock in Profile; does not re-add to the watchlist; blocked films can't be re-added from Search until unblocked).
- **Exclusions** in the engine's precedence: blocked, offered this session, tonight's avoided genres, unknown runtime under a cap, over the cap. A film offered once today is never offered again.
- **Pause** on the third rejection: no automatic replacement; Adjust tonight's context, Continue once (one film, count not reset), or Stop. Unchanged or mood-only context → `CONTEXT_REVIEW_REQUIRED`; a genuine scoring change allows one attempt.
- **Edit tonight** (`/today/context`): Save or Pick with this context; mood-only edits keep the pick, scoring changes clear it (visible confirmation when replacing an accepted plan); back changes nothing.
- **No match**: aggregate counts that sum to the candidate count, Adjust context / Add movies; never an error, no limit relaxed, nothing outside the watchlist.
- **Feeling down** reveals the four documented follow-ups (Cheer me up, Something comforting, Let me feel it, Surprise me); nothing is preselected.
- Scripted selection stays non-ranking: P1a order first, then remaining eligible films in watchlist order; a film whose genres don't match the intent says so ("Its genres don't clearly match …").
- Profile: natural-language context shown as "Coming later"; account and preference sections marked read-only ("Editing is coming later").
- `core/state/revision.dart`: a counter Today bumps after watchlist/viewing/block changes so Watchlist, watched history and Profile reload without features importing each other.

### Verified

| Check | Result |
|---|---|
| `dart format --output=none --set-exit-if-changed lib test` | 0 changed |
| `flutter analyze` | No issues found |
| `flutter test` | 49 passed (P1a + P1b + 23 P1c): accept is intention; Mark watched completes once and locks the day; rating replaces; one new film per replacement and no same-session repeats; third-rejection pause, mood-only and unchanged context blocked, Continue once without reset, real change allowed; Stop; Already seen; Never recommend block/unblock; Too long cap validation (invalid request changes nothing); Different genre validation and exclusion; Something lighter; Edit tonight invalidation rules; honest no-match counts incl. tight cap; mood never changes the pick sequence; screen flows for Pick another, pause/Continue once, Watch Tonight → Mark watched with rating → History, no-match view, feeling-down follow-ups, Edit tonight Save and back-cancel, Profile "Coming later", all lifecycle screens at 360×640 / 200% text |
| Emulator 411dp | Down follow-ups; offered card with Already seen / Pick another / Watch Tonight; reason sheet incl. genre and shorter-limit options and third-pass note; two replacements; pause; Continue once → no match with counts; History recommendations with reasons; More actions; Already seen dialog; Edit tonight mood-only Save kept the film; accepted; Mark watched sheet with rating; completed card; Profile |
| Emulator 360×640dp at font scale 2.0 | Offered, reason sheet and accepted screens usable; content scrolls with actions visible |

Found and fixed during verification: a 200%-text overflow in the context line + Edit tonight row; reasons pushed below the fold once two action rows existed (art now sized from the available height); app-bar tint on Edit tonight. Note: the C: drive filled up again and `flutter test` hung silently until `%TEMP%` was redirected to D: (TOOLING updated).

### Not in P1c

- Session versions, idempotency keys and conflict-reload behaviour are backend/HTTP concerns (P2+); the fake has no versions.
- Daily attempt cap (20/day, `daily_limit` outcome), day rollover/timezone, `too_serious` and `other` reasons with notes, advanced context controls (prefer genres, pace, complexity), "Why?" detail drawer, rating edits from History rows, movie details, sign-out (P2), preference editing (P3).
- Visual polish deferred until real imagery arrives in P3.



Four-tab stateful shell (Tonight, Watchlist, History, Profile) plus a nested full-screen `/search`. Each feature has a repository interface whose provider is null in normal builds; the preview build wires every fake from `lib/preview/` over one in-memory `PreviewStore`, which keeps the cross-screen rules: Tonight picks only from the active watchlist; removing a film or logging it as already watched archives it and, if it was tonight's pick, clears it (recorded as cleared) without choosing another; picks appear in recommendation history. Today now reads `GET /today`-style state (`not_started`, `empty_watchlist`, `offered`) and re-reads after inventory changes, never re-picking.

- **Watchlist:** inventory rows (placeholder thumbnail, title, year · runtime, date added), 20 per page with automatic load more, remove behind a confirmation and only after success, empty state with Add movies.
- **Search/Add:** 300 ms debounce, 2-character minimum, stale responses discarded, paged results, separate Add to watchlist / Already watched (confirmed; unknown date, no rating). Distinct states: in watchlist, watched, can't be added (labelled fixture), no results, search unavailable.
- **History:** Watched / Recommendations, "Date unknown · recorded …", rating as a text label; read-only.
- **Profile:** read-only shell with UTC default, preferences, blocked films, TMDB notice; preview-only "Simulate connection errors" switch.
- **States:** bounded skeletons, empty states with one action, errors with Retry; failed refresh or load-more keeps loaded rows and says so.
- Riverpod 3's automatic provider retry is disabled (`noAutomaticRetry`) so failures stay visible and retries explicit.

### Verified

| Check | Result |
|---|---|
| `dart format --output=none --set-exit-if-changed lib test` | 0 changed |
| `flutter analyze` | No issues found |
| `flutter test` | 26 passed (10 P1a + 16 P1b): paging; remove clears tonight's pick without re-picking; Tonight only picks active films; duplicate/watched/ineligible add outcomes; already-watched is unknown-date, archives, idempotent and never completes Tonight; empty watchlist never picks; search runtime hidden until known; debounce/min-length/stale-response guard; tab navigation with Tonight still one film; confirmed, non-optimistic remove with failure kept; load error Retry, failed refresh and load-more keep rows; empty states; search add/watched/ineligible/no-results; removing the current pick returns Tonight to context; all tabs and search at 360×640 / 200% text; normal build shows no fake inventory |
| Emulator 411dp, preview APK | Tabs, Watchlist remove with dialog, Search add and already-watched (snackbars and row states), can't-be-added fixture, no results, History both segments, Profile, simulated errors: Watchlist refresh failure kept rows with message, search unavailable panel, History load error then Retry |
| Emulator at font scale 2.0 and at 360×640dp + 2.0 | All tabs and search readable; Tonight context scrolls to an inline Pick button on short screens; History segment pills wrap whole words |

### Not in P1b

- P1c: Already seen/Pick another/replacement sheet, pause, accept vs watched states, Edit tonight, no-match state (the fake still throws if no scripted film is available).
- Movie detail route `/movies/:id`, rating edits in History, Watchlist in-list filter, sign-out (P2), profile/preference editing (P3), TMDB logo asset in About (text notice only), same-day re-offer exclusion (I09) in the fake.



Context-first Tonight: required desired experience (8 documented intents), separate optional mood, optional time cap, then "Pick my movie" shows exactly ONE film (designed placeholder poster, title, year, runtime, genres, 1–2 factual reasons, primary Watch Tonight). Data comes from `FakeTodayRepository` (fixed per-intent lists filtered by the hard runtime cap; mood ignored), wired only with `--dart-define=CINEME_PREVIEW=true`. Normal builds still show "not available in this build" with no fake data.

### Verified

| Check | Result |
|---|---|
| `dart format --output=none --set-exit-if-changed lib test` | 0 changed |
| `flutter analyze` | No issues found |
| `flutter test` | 10 passed: every intent × time option stays inside the cap; mood never changes the pick, Sad+Comfort ≠ Sad+Let me feel it; unknown runtime excluded under a cap; reasons factual; normal build shows no fake movie; Pick disabled until an intent (mood "Down" selects nothing); 500-film watchlist renders exactly one movie and no later-milestone actions; Watch Tonight shows intent-only note; 360×640 at 200% text with no overflow |
| Emulator (emulator-5554, preview APK) | Context screen → Keep me hooked + Tired + Up to 90 min → Pick my movie → one card: Run Lola Run, 1998 · 81 min, Action/Drama/Thriller, 2 reasons; intent and mood shown as separate tags; Watch Tonight shows the preview note and the card stays. Repeated at system font scale 2.0: both screens readable, content scrolls, Watch Tonight stays visible |

### Visual revision (same day, presentation only)

Movie screen rebuilt around full-width artwork fading into charcoal, then a compact block (context line, title, "year · runtime · genres" text line, up to two factual reasons) anchored on Watch Tonight; no page gradient, glow, badge, pills or section labels. Context screen uses the same type scale and quieter labels; the pinned "choose to continue" hint became a screen-reader hint on the disabled button. Typography: bundled Jost (OFL). Local preview posters per [ADR 002](adr/002-preview-posters.md). Repository, controller, scripted selection and reasons logic unchanged; test copy assertions updated to the new wording and one assertion added for the disabled-button hint.

| Check | Result |
|---|---|
| `dart format --output=none --set-exit-if-changed lib test` | 0 changed |
| `flutter analyze` | No issues found |
| `flutter test` | 10 passed |
| Emulator 1080×2424 (411dp) | Context → Keep me hooked + Tired + Up to 90 min → Run Lola Run with a local preview poster (synthetic generated test image, since deleted); Make me laugh → Groundhog Day with placeholder fallback; Watch Tonight note shown |
| Emulator at font scale 2.0 | Both screens readable; Past Lives card scrolls to show both reasons; button stays visible |
| Emulator 720×1280 @320dpi (360×640dp), scale 1.0 and 2.0 | Context screen scrolls with the button pinned; movie title and metadata visible above Watch Tonight at 2.0, reasons reachable by scrolling |



- Already seen, Pick another, replacement sheet, pause, accepted/completed states, Edit tonight (P1c); loading/empty/error states beyond an inline pick error, Watchlist/History/Profile (P1b).
- Down-mood follow-up shortcut (optional in spec); mood is a separate optional row instead.
- No real posters are included: the preview shows developer-supplied local files if present (ADR 002), otherwise placeholders; `poster_url` stays null until TMDB (P3/P4).
- Picking in this preview is in-memory; restarting the app returns to the context screen.



### Verified

| Check | Result |
|---|---|
| `uv run ruff check .` | All checks passed |
| `uv run ruff format --check .` | 7 files already formatted |
| `uv run mypy app` (strict) | No issues in 4 source files |
| `uv run pytest` | 6 passed (health, production docs hidden, settings defaults/env/invalid) |
| `dart format --output=none --set-exit-if-changed lib test` | 0 changed, exit 0 |
| `flutter analyze` | No issues found |
| `flutter test` | 1 passed (launch on Today placeholder) |
| `docker compose --env-file infra/.env -f infra/compose.yaml config --quiet` | Exit 0; clear error when `POSTGRES_PASSWORD` is unset |
| PostgreSQL `up -d` + `ps` | Container reported `(healthy)` (confirmed by the user) |
| `git check-ignore -v infra/.env` | Ignored by `.gitignore:2:.env` |
| Manual: `uvicorn` + `Invoke-RestMethod /healthz` | `{"status":"ok"}` |
| Manual: `ENVIRONMENT=bogus` | Startup fails with a validation error naming `environment` |
| `flutter build apk --debug` | Exit 0; `app-debug.apk` produced |
| Android launch | `flutter install -d emulator-5554` (Android 17, API 37 emulator) with the D: cache workaround; `dev.cineme.cineme/.MainActivity` was the top resumed activity; screenshot showed the dark "Cinemé / One movie. No scrolling. / Tonight's pick is not available in this build yet." placeholder |

### Outstanding

- **CI workflow:** verified. [Run 36962545446](https://github.com/shewfx/Cineme/actions/runs/36962545446) on `feat/p0-setup` (commit 29981c2): backend, frontend, compose all succeeded. Runner notices to address later: actions/checkout@v4 and setup-uv@v6 target deprecated Node 20; `ubuntu-latest` moves to Ubuntu 26 from 2026-10-19.
- **Request-ID header:** resolved in P2 (error envelope plus `X-Request-ID` on every response, covered by tests).

### Known notes

- `uv run pytest` reports 1 warning, emitted by **starlette 1.7.0** (`starlette.testclient`, imported via `fastapi/testclient.py:1`, fastapi 0.142.2) when it detects httpx 0.28.1:
  ``StarletteDeprecationWarning: Using `httpx` with `starlette.testclient` is deprecated; install `httpx2` instead.``
  Tests still pass. HTTPX stays (ARCHITECTURE A02); the warning alone is not a reason to switch. Revisit at P3 or when a Starlette release drops httpx support.
- Dio and the Riverpod `AppConfig` are deferred until the first HTTP call ([ADR 001](adr/001-baseline.md)).
- The C: drive was full during setup; pub/Gradle caches were redirected to `D:\cineme-tool-cache` ([TOOLING.md](TOOLING.md#low-disk-space-on-c)). The Android SDK on this machine is at `F:\astudio` (adb is not on PATH).
