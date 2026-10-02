# Implementation status

Records only verified work. Phases follow [DEVELOPMENT_PLAN.md](../DEVELOPMENT_PLAN.md).

| Phase | Status |
|---|---|
| P0 — Bootable repository skeleton | Complete: local gates, manual launch/health and GitHub Actions CI verified; request-ID header implemented in P2 |
| P1a — Context to one movie card (fake data) | Complete: merged to `main` in PR #2 (CI green) |
| P1b — Inventory, history, profile, loading/empty/error (fake data) | Complete: merged to `main` in PR #3 (CI green) |
| P1c — Feedback, replacement, pause, accept vs watched, no match (fake data) | Complete: merged to `main` in PR #4 (CI green) |
| P2 — Auth, profile bootstrap, persistence foundation | Complete: merged to `main` in PR #5 (CI green incl. PostgreSQL); cross-account movie-data isolation deferred to the P3 two-account test |
| P3 — TMDB search and persistent watchlist | Ready for commit on branch `feat/p3-tmdb-watchlist` (uncommitted): all automated gates pass incl. PostgreSQL; single-account emulator checks passed with live TMDB; two-account isolation passed (project owner, 2026-10-02) |
| P4–P8 | Not started |

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
