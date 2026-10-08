# Cinemé roadmap after v1.0.3

Planning document. Housekeeping (§1.2 items 2, 3, 4, 6, 7) and Release 1 (§3) were carried out on 2026-10-08 on `feat/onboarding-v1.1.0`; see `IMPLEMENTATION_STATUS.md` for what was verified. Nothing here is deployed or migrated on the hosted database. Release 1 differences from the plan below: Continue is always enabled (an empty list leads to Tonight's honest empty state), the migration is `0007`, the version is `1.1.0+5`. It records what was verified in the repository on 2026-10-08 (HEAD `273e48e`, tag `v1.0.3`, `frontend/pubspec.yaml` `1.0.3+4`), then plans four features in priority order. Where this file and a normative document (`API_CONTRACT.md`, `DATA_MODEL.md`, `RECOMMENDATION_ENGINE.md`, …) disagree about a *planned* change, the normative document is updated in the implementing task together with an ADR; this file is not a contract.

Authority order for anything below: repository code and tests, then the normative documents, then this roadmap.

## 1. Confirmed state

### 1.1 Already shipped (verified in code, not re-planned)

| Item | Evidence |
|---|---|
| Watchlist movie details | `/movies/:tmdbId` route in `app_router.dart`, `movie_details_page.dart`; `IMPLEMENTATION_STATUS.md` 2026-10-04 |
| Integer 1–5 ratings | migration `0006_integer_ratings.py`; `rating_stars.dart`; `MarkWatchedRequest.rating` is `int 1..5` |
| Root-tab swipes | `_AppShell` pointer handling, `tab_swipe_exclusion.dart` |
| Shared scroll-depth hint | `core/widgets/scroll_depth_hint.dart` (Movie Details and Tonight) |
| Regional availability | `movies/availability.py`, `availability_section.dart`, `GET /watch/regions`, `PATCH /me country_code` (ADR 007) |
| Provider priority, 3 chips, “+N more” | `availability_section.dart` (rank function; `'+$hiddenCount more'`) |
| Logo, red “mé” wordmark, icons | `assets/branding/`, commits `d9c3fcd`, `99f6946` |
| About version/build, release workflow | `package_info_plus`, `docs/RELEASING.md`, `CHANGELOG.md`; live `/version.json` reports `1.0.3`, build `4` |
| Follow-up “Did you watch it?” (core) | **Largely shipped in P5**, see §4; the backlog item is a refinement, not a new feature |

### 1.2 Status corrections (repository evidence vs. backlog and docs)

1. **Follow-up is not missing.** `POST /recommendations/{id}/follow-up`, columns `follow_up_prompted_on`/`follow_up_resolved`, `TodayEnvelope.follow_up`, `FollowUpBanner` and the idempotent “yes → canonical viewing” path exist. Only rating, dismissal limits and a few eligibility rules are missing (§4).
2. **Hosted migration level is contradictory.** `IMPLEMENTATION_STATUS.md` says the hosted database is at `0004` and that `0005`/`0006` were not applied, yet the live site serves v1.0.3 and `/readyz` returns `ready`, which `DEPLOYMENT.md` defines as “database at the code’s head”. Either the status text is stale or the deployed backend is older than the web bundle. **Unverified from the repository. Resolve with `scripts/migrate_hosted.py` (dry run) before any new migration is written for release.**
3. `IMPLEMENTATION_STATUS.md` has no entry for v1.0.2/v1.0.3 (branding, About/version); only `CHANGELOG.md` records them. Its P5 prose still lists the old `loved/liked/okay/disliked` ratings; the section at the top (migration 0006) is the current truth.
4. `API_CONTRACT.md` `GET /me` example omits `country_code` and `region`, which `MeResponse` returns.
5. No OpenAPI snapshot exists (deferred in P3), although `CLAUDE.md` asks for one on contract changes. Contract tests stand in for it; do not create the snapshot as a side effect of a feature.
6. `docs/RELEASING.md` covers versioning only. There is no written Android build/sign/distribute runbook; `frontend/android/app/build.gradle.kts` requires a git-ignored `key.properties` and keystore (both confirmed ignored). The last *distributed* Android version code is not recorded; the repository only shows `+4`.
7. Untracked files that must not be swept into a feature commit: `hs_err_pid33460.log`, `replay_pid33460.log` (JVM crash dumps), `backend/.gitignore`, `branding/`. Add the crash dumps to `.gitignore` in the first implementation task.
8. `PROJECT_SPEC.md` “Non-goals” states **“No TV”**. Series work is a documented scope change and needs an ADR (§5).

### 1.3 Release facts

- Latest release: **v1.0.3** (tag on merge `273e48e`), pubspec `1.0.3+4`.
- Policy (`docs/RELEASING.md`): PATCH = fixes and small visual changes; MINOR = compatible new features; MAJOR = incompatible. `pubspec.yaml` is the only version source; Android code must exceed every shipped one.
- Flow used so far: `release/cineme-vX.Y.Z` branch, PR, merge, tag, then explicit web deploy (Vercel CLI) after explicit migration (`migrate_hosted.py --apply`).

## 2. Recommended release sequence

| # | Release | Scope | Schema | Depends on |
|---|---|---|---|---|
| 0 | housekeeping (no version) | Resolve contradiction 1.2-2; record last shipped Android code; ignore crash dumps; status-doc fixes | none | — |
| 1 | **v1.1.0+5** | New-account onboarding (§3) | `0007` users column + backfill | 0 |
| 2 | **v1.2.0+6** | Follow-up refinements (§4) | `0008` small column + backfill | 1 (migration order only) |
| 3 | **v1.2.1+7** | Android poster disk cache (§5) | none | none; may ship before 2 if wanted |
| 4 | v1.3.0 → later | Series (§6), staged S0–S5, each a MINOR | additive tables | ADR; 1–3 |

Why this order: onboarding is the only item that changes first-run success and has no dependency; the follow-up is a small, contract-additive change on a shipped path; the poster cache is a pure performance PATCH and can float; series changes the data model and the engine and must not be mixed with anything. Series stays MINOR (not 2.0.0) because every step is compatible with existing users and old clients (§6.7). Version numbers are provisional: re-read `pubspec.yaml`, `git tag` and the live `/version.json` immediately before assigning them, and verify the Android code against the last APK actually distributed.

Every release uses the same rollout order (already the documented rule): migration first, tolerant backend second, web third, APK last; contracts are additive, new response fields are optional for old clients, and new clients treat a missing field as “feature absent”.

## 3. Release 1 — New-account onboarding (v1.1.0)

### 3.1 Current behavior

Sign-up → (email confirmation via Supabase if enabled) → sign-in → `POST /me/bootstrap` → `GET /me` → `AuthGate.ready` → `/today`. A new user lands on Tonight with an empty watchlist and sees the existing `empty_watchlist` state with an “Add movies” button (`today_states.dart`). Nothing introduces the product. Search (`SearchPage`) already adds through `POST /watchlist` with idempotency keys and retry-key reuse, and has `logMode`. The profile has no onboarding state.

### 3.2 Product behavior

Trigger is **server state on the profile**, not a client event, so it works after email confirmation on another device and on resume.

1. **Welcome** — “One movie. No scrolling.” Two or three short lines: you choose a mood and time, Cinemé picks one film from *your* list. Primary: “Add movies”. Secondary: “Skip for now”.
2. **Add** — search field + results (the existing search panel), counter “N added · five is a good start”, never “N of 5 required”. Each Add saves immediately via `POST /watchlist`. Controls: **Skip** (always available) and **Continue** (enabled once ≥1 film is on the watchlist; after five the counter reads “That’s a good start. You can add more any time.” and nothing auto-advances).
3. **Finish** — Skip or Continue marks onboarding complete, then navigates to `/today` (the existing mood/time flow). No pick is generated by finishing. Zero films → Tonight shows the existing honest empty state; no film is invented.

Existing users are never shown onboarding (§3.4).

### 3.3 Behavior definitions

| Case | Behavior |
|---|---|
| Resume | Opening the app with onboarding incomplete lands on step 1 if the watchlist is empty, else directly on step 2 with the real count. Count always comes from the server (`GET /watchlist?limit=5`), never a local tally. |
| Cross-device | Completion is a server timestamp; the other device’s next `GET /me` routes to Tonight. |
| Add succeeds | Row becomes “In watchlist”; counter increments; screen-reader announcement “Added <title>. N added.” |
| Duplicate add | Server returns 200 `already_present` → row shows “In watchlist”, snack bar says it is already there; counter derives from distinct server entries so it cannot double count. |
| Add fails (network/5xx) | Existing connection snack bar; row stays “Add”; the retry-key mechanism (`RetryKeys`) replays the same command, so a lost response cannot create a second entry. |
| Add rejected (409 watched / blocked, 422 ineligible, 409 limit) | Existing per-outcome messages; counter unchanged. “Already watched” action is **hidden** in onboarding (third search mode); logging history is not an onboarding task. |
| Partial failure | Each add is independent and already persisted; there is no batch. Nothing is rolled back. |
| Search unavailable | Existing error panel with Retry; Skip stays enabled. |
| Complete call fails | Stay on screen, show a retry message, do not navigate (a navigation without the server write would re-show onboarding next launch). The watchlist is already saved. |
| Back (Android/system/browser) | From step 2 returns to step 1; from step 1 the app backgrounds/exits like any root screen. Back never completes onboarding and never opens Tonight. Search keyboard dismisses before back is handled. |
| Sign-out | Available from the onboarding app bar so a user is never trapped. Account switch re-evaluates for the new user. |
| Deep links / URL bar | The router redirect sends every private route to `/onboarding` while incomplete; the completed state never redirects back. |
| Preview build | Skips onboarding entirely (no identity). |
| Missing field (older backend) | Treated as **completed**. A client must never force onboarding on ambiguity. |
| Accessibility | Headings exposed as headings; counter is a live region; ≥48 dp targets for new controls (existing `_SmallAction` is 44 dp — bring it to 48 in the extracted panel or flag it); works at 200 % text on 360×640 (stacked actions as search already does); focus order title → search → results → Skip/Continue; actions pinned above the keyboard; no state conveyed by colour alone; reduced motion disables any transition. |

### 3.4 Data, API and compatibility

- **Schema (migration `0007`)**: `users.onboarding_completed_at timestamptz NULL`. Backfill every existing row to `created_at` (so no current user is ever sent through onboarding). New rows default to NULL. No separate “skipped” column and no stored step: progress *is* the watchlist, outcome is a single timestamp. (Rejected: a status enum — it would encode distinctions the product does not use.)
- **Read**: `GET /me` / `MeResponse` gains nullable `onboarding_completed_at`.
- **Write**: `PATCH /me` gains `onboarding_completed: true` (only `true` is accepted; monotonic; a repeat keeps the original timestamp). It reuses the users-row lock, Idempotency-Key and replay already in ADR 003, so no new endpoint. Unknown-field rejection stays. Rejected alternative: a dedicated `POST /me/onboarding` — a second idempotent command surface for one boolean.
- **Contracts to update together**: `API_CONTRACT.md` (`MeResponse`, `PATCH /me`), `DATA_MODEL.md` (`users`), `FRONTEND_SPEC.md`, new `docs/adr/010-onboarding-completion.md`, `IMPLEMENTATION_STATUS.md`, `CHANGELOG.md`.
- **Rollout/skew**: new client + old backend → field absent → no onboarding. Old client + new backend → ignores the field; users created in that window have NULL and will see onboarding once on a new client. Hosted order: dry-run, `--apply` `0007`, deploy backend, build/deploy web, then APK `1.1.0+5`. Migration is forward-only on hosted data; the downgrade drops the column and is for local/CI only.

### 3.5 Frontend changes (likely files; confirm on inspection)

- `shared/models/profile.dart`, `features/auth/data/account_repository.dart`: parse the field (absent ⇒ completed) and send the PATCH.
- `features/auth/application/auth_controller.dart`: `accountProvider` must be able to update its value after completion without re-running bootstrap (avoid the “setting up” flash); add an `AuthGate.onboarding` outcome.
- `routing/app_router.dart`: `/onboarding` (outside the tab shell, no nav bar) and the redirect rules, including the swipe/shell exclusion.
- `features/search/presentation/search_page.dart`: extract the query field + results + `_ResultRow` into a public panel and add a third mode (`add` / `log` / `onboarding`) rather than copying it. **Verify** that `searchControllerProvider` state (`marks`, `busy`) does not leak between the onboarding instance and the later Search page.
- New `features/onboarding/` (page + small controller for step and count). No new dependency.
- Tonight keeps its current empty-watchlist state; no change expected.

### 3.6 Acceptance criteria

- [ ] A brand-new account (after confirmation, sign-in, bootstrap) sees the welcome screen exactly once and never again after Skip or Continue, on any device.
- [ ] Every account that existed before the migration goes straight to Tonight.
- [ ] Adding a film from onboarding appears in the Watchlist tab; duplicates, failures and rejections behave as in §3.3 without double counts.
- [ ] Skip with zero films reaches Tonight’s honest empty state; no film is offered or invented.
- [ ] Closing the app mid-onboarding and reopening (same or another device) resumes with the correct count.
- [ ] A failed completion call keeps the user on the screen and is retryable; replaying the same Idempotency-Key does not change the timestamp.
- [ ] Android/browser back never skips onboarding.
- [ ] A client talking to a backend without the field never shows onboarding.
- [ ] Layout and semantics hold at 360×640, 200 % text and 1440 px desktop.
- [ ] All existing Tonight, search, watchlist and rating tests pass unchanged.

### 3.7 Validation scope

Backend (PostgreSQL): migration up/down/up with backfill assertion; `GET /me` shape; `PATCH /me` completion is idempotent and monotonic, rejects `false`/other values, is per-user (user B cannot affect A), replays with the same key and conflicts on a different body; two-user isolation; existing P2 tests unchanged. Full `ruff`, `format --check`, `mypy`, `pytest`.
Flutter: gate routing table (pending / completed / field absent / preview / account switch); onboarding widget tests over fake repositories for each row of §3.3; semantics assertions; 200 % text; search panel regression (`search_rows_test`, `real_inventory_test`); `dart format`, `flutter analyze`, `flutter test`; web build + `infra/check_web_bundle.py`.
Manual (next session, if devices are available): fresh account on Chrome at 390 px and, separately, Android; confirm-email path; sign-in on a second browser mid-onboarding.

### 3.8 Next-session scope (authorized unit: “Onboarding v1.1.0”)

Branch `feat/onboarding-v1.1.0` from `main` (CLAUDE.md: never work on `main`). In order:
1. Verify hosted migration level (dry run) and the last distributed Android code; write down both.
2. ADR 010; update `API_CONTRACT`, `DATA_MODEL`, `FRONTEND_SPEC`.
3. Backend: migration `0007`, model/schema/service/PATCH change, tests.
4. Frontend: profile parsing, gate/route, extracted search panel with `onboarding` mode, onboarding page/controller, tests.
5. `pubspec` `1.1.0+5`, `CHANGELOG`, `IMPLEMENTATION_STATUS` (verified work only).
6. Run all gates; report; **stop**. No commit/push/deploy/hosted migration unless separately requested. Out of scope: replay-onboarding in Profile, rating or “Already watched” inside onboarding, genre/runtime preference questions, any recommendation change.

## 4. Release 2 — “Did you watch it?” refinement (v1.2.0)

### 4.1 What exists (keep)

`recommendations.follow_up_prompted_on`, `follow_up_resolved` (+ partial index); `GET /today` surfaces the newest accepted, unresolved recommendation from an **earlier user-local date** unless `prompted_on` is that date or later; actions `yes` (canonical viewing path, recommendation → `watched`, watchlist entry archived, session completed), `no` (resolve, no viewing, inventory untouched, no feedback row), `not_yet` (suppress until a later local date); same-key retry replays; the banner is a small overlay on Tonight. Accept already means intent only; Mark watched is the only completion on the day itself.

### 4.2 Gaps (the only new work)

| Gap | Evidence | Plan |
|---|---|---|
| “Yes” cannot rate | banner has no rating step; `FollowUpAction` has only `action` | “Yes” opens the existing rating selector (optional, Skip rating); one call `action:"yes", rating?: 1..5` — additive, atomic, body-hashed for idempotency. Rejected: two calls, because the follow-up response (`TodayEnvelope`) does not carry the new viewing id. |
| Repeated nagging | `not_yet` re-asks on **every** later day forever; no dismiss; no expiry | Add `follow_up_deferrals smallint` (`0008`; backfill 1 where `prompted_on` is set). A prompt is eligible only while deferrals < 2 **and** the accepted local date is within 7 local days. “Not now” (also the banner’s close control) counts as a deferral; the third occasion never appears. Expiry is computed in the read query — no job, no GET mutation. |
| Already-watched film still prompted | query does not check `viewings`/watchlist/blocks (confirm in code before changing) | Not eligible if a viewing for that movie exists (logged elsewhere), or the movie is blocked. A removed watchlist entry does not block the prompt (the user may still have watched it). |
| Watch date | `yes` stores `watched_at = now` (the answer time), which can mislead History | Open question Q4. |
| Banner UX | overlay pinned to the top of Tonight with text buttons; no dismiss; unclear targets | Keep the placement (it is a question, not a second recommendation; the single actionable film is unaffected) but add a dismiss control, 48 dp targets, heading semantics, and make sure it never covers the primary action at 200 % text. |

### 4.3 Eligibility and timing rules (target state)

Eligible when all hold: recommendation `status = accepted`; `follow_up_resolved = false`; session local date < caller’s *current* local date (profile timezone at request time; a timezone change can move a date backward, in which case the prompt simply appears later); within 7 local days; deferrals < 2; not asked yet today; no viewing/block for the film. Exactly one prompt at a time (newest first, as now). Evaluated only when Tonight is read; no push, no background work (non-goals). Watch intent (accept) and completion (viewing) stay separate; `no` and expiry create **no** dislike, block, rejection feedback or rating.

### 4.4 Idempotency

Unchanged mechanism: `Idempotency-Key` + users-row lock + recheck. Same key and body replays the stored envelope. Different rating with the same key → `IDEMPOTENCY_CONFLICT`. A second device answering after the first → 409 `INVALID_TRANSITION` (already resolved) which the client treats as “reload Today”. The canonical viewing path already prevents a duplicate viewing per user/movie.

### 4.5 Acceptance and validation

Acceptance: yes→rating→History shows one viewing with that rating; yes without rating records none; no leaves watchlist, ratings and blocks untouched; Not now twice then never again; not shown on the accepted day, after 7 days, after the film is logged elsewhere, or when blocked; retries and double taps create one viewing; second device is safe.
Tests (PostgreSQL): eligibility matrix with injected `now` across timezones/DST and a mid-flight timezone change; deferral cap and window; replay/conflict; concurrent yes+yes and yes+no; ownership (404 for another user’s recommendation); migration backfill. Flutter: banner states, rating sheet, dismiss, 200 % text, stale-version reload, existing `real_today_test`/`feedback_test` unchanged.
Contract/deploy: additive request field and one column; migration `0008` before backend; old clients never send `rating` and keep working.

## 5. Release 3 — Local poster caching (v1.2.1)

### 5.1 What exists

- Posters are public TMDB CDN URLs (documented exception), built by the backend as `…/t/p/w500/<path>` (`POSTER_SIZE = "w500"` for *every* surface, including 76×114 search thumbnails and the 3-column grid).
- `MoviePoster` uses `Image.network` with a same-size placeholder for loading, failure and missing posters.
- **Web:** the browser’s HTTP cache already applies; there is no service worker and `DEPLOYMENT.md` says API responses are never cached. Revalidation depends on TMDB’s CDN headers — **not verified here**; check one poster’s `Cache-Control` as the first step of the task.
- **Android:** only Flutter’s in-memory `ImageCache`; `dart:io` has no HTTP cache, so every cold start re-downloads every visible poster. This is the real gap.

### 5.2 Plan

1. **No-dependency step first:** pass a decode width (`cacheWidth`) matched to each surface so thumbnails stop decoding 500 px bitmaps (memory, not bytes). Measure before/after.
2. **Android disk cache:** add `cached_network_image` (brings `flutter_cache_manager`, `sqflite`, `path_provider`); resolve and pin compatible versions and commit the lockfile. Rejected: hand-rolled Dio + `path_provider` LRU (more code to get wrong: concurrency, corruption, eviction); changing API payloads or adding a service worker (web needs nothing); leaving Android as is (cold-start churn on every list). Web keeps its current `Image.network` path via `kIsWeb`.
3. **One wrapper:** keep `MoviePoster`’s public API, fit and placeholder; swap only the image provider. The preview build is unchanged.
4. **Bounds and policy:** dedicated `CacheManager` (own key, not the default shared one) with a hard object cap (start at 300; a w500 JPEG is typically tens of KB, so tens of MB — measure and record the real figure; `flutter_cache_manager` caps by count/age, not bytes), stale period 30 days, least-recently-used eviction. Cache key = URL (TMDB poster paths change when a poster changes, so no manual refresh). Failure: cached copy → show it even if the network fails; none → existing placeholder; undecodable file → evict, one refetch, then placeholder. Never cache `Dio` API traffic. Clear the poster cache on sign-out (the files can reveal a user’s titles on a shared device).
5. **Honesty:** no offline claim in UI or docs; posters appearing offline is incidental.

### 5.3 Acceptance and validation

Repeat visit in airplane mode shows previously seen posters while data screens still show their normal errors; cold start with network on does not re-request cached posters (verify by request count with a fake cache manager, not live TMDB); cache never exceeds the cap after browsing >cap posters; fallback layout identical; sign-out empties it. Widget tests with an injected manager (no network in CI), `flutter analyze`/`test`, APK secret/bundle scan unchanged. Manual on an emulator only when authorized.

## 6. Release 4+ — TV series and anime series (later, staged)

> Superseded by [SERIES_DESIGN.md](SERIES_DESIGN.md) and [ADR 011](adr/011-shows-and-anime-next-episode.md) (proposed, 2026-10-08). The sketch below is kept for history; where it differs, the design document wins.

Large, separate effort. Requires a scope-change ADR (011) lifting the “No TV” non-goal in `PROJECT_SPEC.md` and amendments to `RECOMMENDATION_ENGINE.md`, `DATA_MODEL.md`, `API_CONTRACT.md` and `FRONTEND_SPEC.md` **before** any code.

### 6.1 Principles

Tonight still presents exactly one actionable item. Movie behavior, tables, tests and `weighted_v1` replays are untouched. Old clients can never receive an episode recommendation. TMDB remains backend-only. Unknown stays unknown; nothing is inferred from genre.

### 6.2 Metadata (TMDB TV API; confirm response shapes with recorded samples in S0)

Search and details for series, season detail for episode lists (one request per season, fetched lazily for the season in play, never inside a transaction), watch providers for TV. Needed fields: series id, name, first/last air dates, status (returning/ended/canceled), genres, poster, vote data, season list, per-episode number, season, air date, runtime, name. Runtime: episode runtime when present; the series-level typical runtime is a *labelled estimate* only if the product allows it (Q-S3); otherwise unknown. Cache TTLs: airing shows short (about a day), ended long. Serverless limit (30 s) and TMDB rate limits argue against fetching whole long-running shows eagerly.

### 6.3 Schema (additive, new tables; movie tables unchanged)

TMDB movie and TV ids overlap, so series cannot share `movies.tmdb_id`. Proposed: `series` (TMDB cache), `series_episodes` (cached per episode), `series_entries` (per user, unique, active/archived like the watchlist, progress pointer `last_season`/`last_episode`, `order_mode` fixed to `standard` at first), `episode_viewings` (per user episode, unique, source, optional `watched_at`). `recommendations` gains `media_kind` and nullable series/season/episode references with a check that exactly one of movie/episode is set; `winner_snapshot` carries the episode. `movie_blocks` stays movie-only until a series-block decision (Q-S7). Rejected: generalizing `watchlist_entries`/`viewings` with a `media_type` column — it touches every movie query and constraint for no near-term gain.

### 6.4 Recommendation semantics

- Context gains `media_preference: movie | episode | either`, **default `movie`** (existing behavior and existing sessions unchanged).
- A series offers at most its single *next unwatched episode in standard order*: first episode after the progress pointer, regular seasons only, **air date ≤ the user’s local date** and known. Unaired or unknown air date ⇒ excluded; “caught up” and “next episode not aired yet” become counted no-match reasons.
- Time eligibility uses that episode’s runtime; unknown runtime is excluded under a cap, as with movies.
- Scoring reuses the deterministic engine with a candidate-kind field; any new component or changed weight is a new engine/config version with worked examples and fixtures, and `weighted_v1` stays replayable. `Either` ranks both pools in one list with explicit total ordering (score, then kind, then ids); whether the scores are genuinely comparable is the main design risk and is settled in S3 with fixtures, not assumed.
- Watch Tonight (accept) never advances progress. Mark watched on an episode, in one transaction: inserts the episode viewing, advances the pointer, resolves the recommendation; idempotent and atomic. Pick another / reject feedback reuse the existing temporary reasons; a rejection is never a dislike of the series.

### 6.5 Progress correction

“Set progress” (season + episode picker, “I’ve watched through S2E5”) moves the pointer in either direction, writes no fake viewings for skipped episodes, and is undoable. Restoring a removed series keeps its progress.

### 6.6 Decisions to make explicitly (not guess)

Specials (season 0), multi-part episodes, episodes TMDB lists out of broadcast order, anime numbering (absolute order, split cours, TMDB episode groups), long-running shows (hundreds of episodes), canceled shows, reboots with reused ids, missing runtimes. Default for the first release: **standard TMDB aired order, regular seasons only, specials excluded and visibly labelled, alternate orders unsupported** and surfaced as “this show’s order may differ” when TMDB exposes episode groups. “Anime” is not a separate type: it is a series; an optional badge (animation genre + Japanese origin) is a display label only and must not feed scoring.

### 6.7 Compatibility and rollout

All steps are additive migrations applied before code. Because `media_preference` defaults to `movie` and only new clients can set it, old clients never see an episode recommendation. Contract additions (`kind`, `episode`) are optional fields on existing envelopes; existing fields keep their meaning for movies.

### 6.8 Stages (each is its own authorized task and MINOR release)

| Stage | Content | Validation focus |
|---|---|---|
| S0 | ADR 011, doc amendments, recorded TMDB samples, decisions in §6.6/Q-S | review only |
| S1 | Series search, details, add/remove to a separate series list, availability; no recommendations | adapter normalization with mocks, ownership, caps |
| S2 | Episodes cache, progress pointer, Mark watched, set progress, episode history | next-episode function with injected time, concurrency (double tap, two devices), idempotency |
| S3 | Engine candidate kinds, `media_preference = episode`, no-match reasons, Why drawer | fixtures/worked examples, shuffled-input determinism, movie regression (existing 57 engine tests unchanged) |
| S4 | `either` | comparability fixtures, ordering totality |
| S5 | Follow-up for episodes, history polish, a11y pass | existing suites + new |

## 7. Unresolved product questions (recommended defaults)

| # | Question | Default |
|---|---|---|
| Q1 | Should Profile offer “Replay welcome”? | No; not in 1.1.0 |
| Q2 | Is five the right nudge, and does Continue need ≥1 film? | Yes; Skip is always available, Continue needs ≥1 |
| Q3 | Show the welcome even if the account already has films (e.g. added on web before first launch)? | Skip step 1, show step 2 once |
| Q4 | Follow-up “Yes”: what `watched_at`? | Keep unknown (`null`, “date unknown”) rather than the answer time, because accept time is intent, not viewing; today’s behavior stores the answer time — change only if the owner agrees |
| Q5 | Number of follow-up asks and window | 2 deferrals, 7 local days |
| Q6 | Clear poster cache on sign-out? | Yes |
| Q7 | Add smaller TMDB poster sizes for thumbnails (contract change) | Not in 1.2.1; revisit after measuring |
| Q-S1 | Include specials | No |
| Q-S2 | Episode ratings | None in the first series releases |
| Q-S3 | Use a series-level typical runtime when an episode runtime is missing | No (unknown stays unknown) |
| Q-S4 | Does watching a series feed genre affinity? | No until the engine amendment decides it |
| Q-S5 | `Either` pool | Both pools, one scoring, subject to S4 fixtures |
| Q-S6 | Caught-up series | Stay on list, excluded, counted in no-match |
| Q-S7 | “Never recommend” for series | Series-level block, introduced in S2 |

## 8. Cross-cutting constraints (all releases)

Preserve the Android package ID `dev.cineme.cineme` and the existing signing identity; never read, print or commit `key.properties`, keystores, `.env`, tokens, APKs or build output. Web shows the deployed `version.json`; Android shows the installed package version. No new dependency without listed purpose and rejected alternatives (only §5 adds one). Run the documented gates (`uv run ruff check .`, `ruff format --check .`, `mypy app`, `pytest` with PostgreSQL; `dart format --output=none --set-exit-if-changed lib test`, `flutter analyze`, `flutter test`, web build + bundle scan) at the end of each release task and report any gate not run. No release is marked done in `IMPLEMENTATION_STATUS.md` until its gates pass and the hosted rollout order has actually been performed.
