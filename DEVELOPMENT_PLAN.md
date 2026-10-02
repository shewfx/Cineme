# Cinemé — gated development plan

Version 1.1. Nine phases P0–P8. Verified progress: [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md). Each task/run implements one explicitly authorized phase or a smaller slice. Do not build everything in one pass. This plan deliberately puts the visible UI prototype first, identity before real private data, and structured context before AI. P2 uses separately gated submilestones so auth cannot become a framework-building marathon.

## Working model

Student A can own backend/data/engine; Student B Flutter/interaction. Both review API contract changes, auth isolation and scoring examples. Review behavior, not generated code volume. Keep a feature branch per milestone; scoped commits only when requested. Progress notes record confirmed work and blockers separately. No phase is complete solely because source files exist.

Each phase delivers: small runnable behavior, meaningful tests, manual verification and a report. Gates below are mandatory when the feature is implemented. If Android/device/Docker/provider tooling is unavailable, distinguish unit checks from unverified end-to-end gates. Do not silently skip them.

## P0 — Bootable repository skeleton

**Objective:** Establish a repeatable Windows workflow with no external account credentials.

**Work:** Inspect existing repo/tooling; initialize git only if task explicitly authorizes it. FastAPI app with settings and GET healthz. Python3.12/uv lock; ruff/mypy/pytest configuration. Flutter Android project with Cinemé title/theme, Riverpod config injection and go_router Today placeholder; introduce Dio only if API configuration foundation needs it, not a fake live endpoint. PostgreSQL16 Compose definition with healthcheck/local-only port binding. Ignore secrets/build artifacts. CI checks. Record exact Flutter/Dart/Python/Docker versions and Windows commands. Baseline ADR references these docs; linked `docs/IMPLEMENTATION_STATUS.md` starts P0 only.

**Likely files:** backend/app/main.py, core/settings.py, tests/test_health.py, pyproject.toml/uv.lock; frontend/lib/main.dart/app.dart/theme/router and test/widget_test.dart; infra/compose.yaml; .gitignore; .env.example files; .github/workflows/ci.yml; docs/TOOLING.md; docs/adr/001-baseline.md.

**Acceptance:** Health200 safe body; invalid settings fail clearly; Flutter placeholder boots; no TMDB/Supabase/LLM secrets required; no tables/auth/business services; compose config validates; formatting/lint/type/static/tests pass on available tools with unmet device prerequisites honestly reported. CI pins recorded Flutter version rather than mutable “latest.”

**Tests/checks:** backend health/settings unit tests; Flutter launch widget test; `uv run ruff check .`, `uv run ruff format --check .`, `uv run mypy app`, `uv run pytest`; `dart format --output=none --set-exit-if-changed lib test`, `flutter analyze`, `flutter test`; `docker compose --env-file infra/.env -f infra/compose.yaml config` at root.

**Manual:** PowerShell terminal starts backend; call Invoke-RestMethod /healthz. Run Android emulator via Flutter; confirm Cinemé placeholder. If Docker installed, start DB and inspect healthy status, without creating tables. Ensure example config contains placeholders only.

**Deferred:** All private endpoints, migrations, auth, actual movie UI/data, ranking, AI and hosting.

## P1 — Cinemé UI prototype with fake repositories

**Objective:** Launch the actual one-movie experience on the emulator before provider accounts or database features.

**Work:** Context-first Tonight with desired-effect chips/optional emotion/time; one poster/title/runtime/reasons/card; Watch Tonight, Already seen and Pick another; accepted/completed/no-match/paused states; compact replacement sheet; inventory Watchlist/Search; History/Profile shells. Match API domain shapes through fake repositories selected only in explicit debug preview. Establish design tokens and meaningful testable controllers, no live ranking/identity/data yet.

**Submilestones:** P1a context->one movie card with scripted fake data; P1b secondary inventory/history/profile and loading/errors; P1c rejection/Already seen/pause/accept-vs-watched preview behavior and accessibility. One Claude run implements only its authorized submilestone.

**Likely files:** frontend/shared/models, features/today/context/watchlist/search/history/preferences, core/widgets/theme, test fake repositories and debug preview entry point.

**Acceptance:** Launch shows what Cinemé actually does; fake500-item inventory never appears as a Tonight feed. Sad does not auto-select comedy; user desired effect controls the draft. First CTA picks one, replacements show one, third rejection pauses. Accept isn't watched. No backend secrets/accounts needed. Preview clearly labeled and not a production fake-success fallback.

**Tests:** Widget/controller tests for context selection, cancellation, one actionable film, feedback fields, two-step meaning of acceptance/completion, loading/empty/error and200% text scaling. No screenshot suite for every small style change.

**Manual:** Run emulator through context->one film->Already seen->one replacement->three skips->pause; inspect inventory/history/profile separately; fail poster; enlarge text. Verify no carousel, Top picks, adjacent alternate or swipe loop.

**Deferred:** Authentication, HTTP requests, persistence, actual scorer, TMDB and AI. The P1 preview contains no private real user data.

## P2 — Authentication plus minimal persistence, in small gates

**Objective:** Supabase handles credentials/sessions; FastAPI verifies identity and owns authorization. Persist only User and UserPreferences at this phase.

**P2a — database foundation:** PostgreSQL connection, Alembic migration for users/user_preferences only, DB readiness and test fixtures. No movie, watchlist, recommendation, viewing, trait or idempotency tables. Tests verify empty DB upgrade/downgrade, default/check constraints and DB failure. Manual run Compose/migration/readiness. Profile changes and data features deferred.

**P2b — SDK identity UI:** Supabase sign-up/sign-in/email verification and refresh with secure Flutter session storage, sign-out/account-switch clearing. Minimal auth screens/routing. No custom password service or JWT framework. Mock SDK state tests plus owned test-account login/verify/logout on emulator. Recovery may be added here if small and explicitly authorized; required before P8 release.

**P2c — explicit app bootstrap:** Thin library-backed JWT verifier; POST me/bootstrap inserts/reuses user/preferences transactionally with identity unique keys; GET me read-only; missing profile conflict; enforce verified identity and bootstrap before private shell. No general idempotency framework: bootstrap is naturally idempotent. Ordinary future resource ownership infrastructure is a small dependency/query scope, not a generic policy engine.

**Likely files:** backend/core/db/settings/auth/errors, users bootstrap/read router/model/schema, two-table Alembic migration; frontend/features/auth/session_store/router; auth/provider and PostgreSQL integration tests.

**Acceptance:** Standard JWT verification via PyJWT/JWKS and configured asymmetric algorithm, wrong identity rejected, bounded provider errors visible. Two identities have separate profiles; concurrent/repeated bootstrap doesn't reset preferences. GET never inserts. Secure sessions/logout confirmed. App tables not exposed through Supabase client Data API. Only two application tables exist. P2c network failures show startup retry, not fake success.

**Tests:** Schema defaults, forged/expired/wrong-issuer/audience token, mocked JWKS rotation/outage, email bootstrap rejection, duplicate/concurrent initialization, read-only GET, two-identity profiles. Keep auth client wrapper small; defer exhaustive key-management tooling to provider. Full resource-isolation tests grow as resources arrive.

**Manual:** Own two test accounts, POST bootstrap twice, read profile; inspect unchanged row count/preferences; confirm auth redirect/account switch; inspect grants. Each submilestone is reported separately; do not authorize all future auth polish by accident.

**Deferred:** Full data model, general idempotency ledger, editable preferences/profile (P3), movie/history/engine services, trait dataset. Password recovery and operational key-rotation smoke test are release gates, not blockers for seeing the P1 UI.

## P3 — TMDB-backed internal watchlist

**Objective:** Authenticated user can search real movies and maintain saved inventory.

**Work:** TMDB adapter/search/details/genre registry/cache/freshness/refresh; normalized movie model; common add command and provenance; list/add/archive endpoints. Add Movie/Watchlist/idempotency tables via additive migration; wire Flutter API client, Search and Watchlist, real editable profile/preferences. Introduce bounded idempotency only now for real writes. Do not depend on curated traits; movie domain traits are null until optional enrichment is enabled. Build source-adapter interface contract without implementing import UI/jobs. OpenAPI contract snapshot and repository tests.

**Likely files:** backend/movies, watchlist, core/http_client; frontend/core/network, features/search/watchlist/preferences/data; provider mocks; OpenAPI fixture.

**Acceptance:** Runtime fetched from details, not fabricated from search. Duplicate add returns existing; cap500; restore resets age; ownership/isolation; unavailable/adult films disabled/rejected; upcoming/unknown-date films saveable but marked not released (ADR 005). Missing runtime/null genres safe. Search throttle/upstream failure visible. Existing cached list works during outage. Correct TMDB attribution present. No unofficial JustWatch endpoint.

**Tests:** Mocked API normal/malformed/null/429/404/timeout; parallel duplicate add; archived restore; ownership; page limits; stale metadata fallback; debounced search ignores old responses; add/remove update list only after success.

**Manual:** Search ambiguous title and verify year; add twice; remove/restore; switch users; disconnect upstream and load saved list; inspect no TMDB token in Android config/logs; verify approved attribution logo/notice.

**Deferred:** Recommendation selection, watched logging, imports, streaming data. Details “Already watched” waits for P5.

## P4 — Deterministic daily selection and evidence

**Objective:** One stable movie can be selected from the watchlist and its score explained.

**Work:** Pure scorer plus affinity helpers/config; additive session/recommendation schema; bounded winner/config/context/exclusion-summary/up-to-nine-comparison storage; GET Today, POST choose/accept; owned recommendation details/comparison/basic history reads. Wire context-first Pick my movie (basic desired effect/time) atomically to real Today and winner-only Why drawer. User locks, version checks and durable attempt limits. Full deterministic replay fixtures in tests, not a production-run archive/CLI. Basic current_mood/desired_experience/time controls are already live; P6 adds advanced editor and NLP.

**Likely files:** backend/recommendations/domain.py, scoring.py, affinity.py, reasons.py, service/router/schemas; config/recommendation_weights.v1.json; frontend/features/today/data/application; scorer/integration tests; tests/fixtures/ranking/.

**Acceptance:** All filters/formulas/tie rules match engine doc and examples. Reopening Today/GET does not create offers. Concurrent choose produces one current pick. Existing offered/accepted choice remains pinned. No-match records and exclusions are accurate. Complete fixtures reproduce ranks after shuffled input; stored bounded comparisons explain retained films using old config without claiming full production replay. No per-candidate score rows. Zero enrichment is a passing baseline. Accept creates no viewing. Render uncertainty, not invented traits.

**Tests:** Pure boundary/metamorphic/tie/example/replay tests;500-candidate benchmark; PostgreSQL parallel chooses/session unique/pointer transactions; next-day timezone/DST fixtures; invalid config fails; no network dependency in scorer; two-user history/comparison isolation.

**Manual:** Use a watchlist with no enrichment; choose an experience/time and one pick; reload and inspect Why; accept and verify no history completion; inspect bounded stored comparison separately from Tonight. Use test fixture clock for midnight, not a production time override. Reject/complete remains unavailable in normal client until P5; explain this incomplete phase in progress report.

**Deferred:** Full rejection/watched/rating flows, applying context and LLM. Do not deploy as finished product yet.

## P5 — Feedback, completion and conservative learning

**Objective:** A genuinely usable selection/rejection/completion loop, with correct long-term evidence.

**Work:** Reject all reason codes with structured effects; movie blocks/unblock; recommendation watched/manual viewings/rating edits; history endpoints/UI; Atomic reject+one replacement/Stop/third-rejection-pause behavior; direct Already seen uses known-history rejection, never tonight completion. Invalidation on relevant preference/watchlist edits. Update Today counts and states. Complete owned duplicate-safe transition services and all-action idempotency. Rating helper recomputes affinity from unique viewing evidence.

**Likely files:** backend/recommendations/feedback/transitions, viewing, users/blocks; frontend/rejection/rating/history controllers/repos; schema refinements only if baseline correction is explicitly documented.

**Acceptance:** Not-tonight changes no taste; never-recommend blocks and archives, unblock does not restore; wrong-genre user-selects genres; too-long never guesses cap. Already-watched records unknown/past date honestly. Mark-watched atomic/history correct; rating null allowed; editing rating replaces evidence. Third rejection must pause instead of auto-selecting; unchanged-context continuation requires explicit Continue once;20attempt cap durable. Failed mutations do not claim success. One deliberate recommendation Mark watched action ends Today. Manual history logging never ends Today; if it makes the current film ineligible, clear/supersede that pick. Preference edits cannot reopen a completed day or erase its card.

**Tests:** Every reason/transition; unchanged affinity temporary refusals; replacement rating evidence; two-account read/write; stale resource/version; same-key retries and different-key duplicate histories; transaction rollback; concurrent reject/watch/remove; unknown watch dates; block/restore; per-session offer exclusions. Widget tests for retaining reason input and ambiguous-timeout retry keys.

**Manual:** Reject one movie temporarily, get another; inspect unchanged preference learning; block/unblock; log already watched; mark selected film watched with liked; edit to disliked and observe a new day's score shift in fixed-clock demo. Force timeout and retry once without duplicate history. Reload each screen and confirm persistence.

**Deferred:** Advanced context editor/NLP, automated trait generation, rewatch/date editing and import. Rejection effects already use validated internal context.

## P6 — Structured tonight context and deterministic time interpretation

**Objective:** Extend already-live lightweight intent/time with advanced context editing, emotion-versus-desired-effect clarification and deterministic time parsing, without an LLM.

**Work:** PATCH complete session context; existing atomic Pick with this context flow; profile/session effective constraints; explicit context supersession; Flutter advanced editor/draft review; deterministic English numeric time parser; `/context/parse` structured fallback path. Field provenance/warnings/unsupported constraints. No raw text saved. Optional reviewed movie_traits migration/seed is an enhancement only; no file/rows remain a supported release baseline.

**Likely files:** backend/context validation/time_parser, today/context routes; frontend/features/context; proposal models; parser fixture corpus.

**Acceptance:** Cap inclusive; “under 2 hours”119; “2h or less”120; “about90”proposed90 with visible review. Stricter profile cap/genre blocks always apply. Save clears a scoring-context-changed current pick without choosing; Pick with this context atomically changes context and returns one. Sad alone requires desired-effect clarification; it never defaults to comedy. Cancel doesn't mutate. Unknown trait neutral. Hard-time no-match never silently relaxes. Conflicting/unsupported time returns review warning.

**Tests:** Boundaries, number words/units/negation/conflict corpus, profile/context union/min, context no-op/version, context vs accept/reject concurrency, completed-day conflict, proposal cancellation/apply widgets. Independent-engine context-change example and lifecycle variant remain separate tests.

**Manual:** Enter sad without intent, then choose Comfort versus Let me feel it; use structured controls/fallback, inspect cap and source; choose with unknown traits; tighten cap to no-match; edit intentionally; cancel unsaved draft and verify no server change. Confirm explicit session replacement excludes an already-offered movie.

**Deferred:** Actual LLM adapter, semantic interpretations beyond supported controls, cloud provider, chat and inferred permanent feedback.

## P7 — Optional local LLM context adapter

**Objective:** Demonstrate schema-constrained natural-language interpretation with controlled authority and failure recovery.

**Work:** ContextProvider protocol plus disabled/Ollama native adapter; explicit opt-in; time-parser precedence; schema and semantic validation; bounded timeout/output, rate limits and provenance; fixed prompt with no movie candidates/history. Choose a locally available model by measured parser quality and record model identifier, quantization where available, prompt/schema hash and test hardware. No assumption any tiny/free model is sufficient.

**Likely files:** backend/ai providers/prompt/contract, context/parse service; frontend opt-in/preview warnings; provider mock tests; docs/AI_EVALUATION.md and LOCAL_AI_SETUP.md.

**Acceptance:** AI can propose supported soft fields; explicit time constraints cannot be weakened. Unknown fields/genres or malformed output rejected. Provider unavailable/timeout ->usable fallback. No session mutation before an explicit Save/Pick action. Emotion alone cannot infer intent or trait targets, invalidate the current film or bypass pause. LLM request excludes watchlist/history/identity; no raw prompts in logs/DB. All deterministic paths work with disabled provider.

**Tests:** Mocked valid/invalid/timeout/refusal/prompt-injection outputs; local semantic checks; explicit-time precedence; no provider call when opt-out; provider contract suite. Evaluate >=25 manually labeled English sentences including sad+comfort, sad+feel_it, emotion-only, tired+exciting, negation, ambiguous time, unsupported language/mood and hostile instruction. Record field accuracy and safe fallback counts, no inflated “recommendation accuracy.” Live-model evaluation is manual/optional CI job, never core test dependency.

**Manual:** Stop Ollama, type sentence and complete recommendation with fallback; restart, inspect proposal/edit/apply; attempt “ignore limits and pick Arrival” and verify AI cannot pick/loosen cap. Check server receives localhost provider URL and emulator only backend URL.

**Deferred:** Cloud adapter, LLM explanations, embeddings, fine tuning and agents. Hosted V1 still uses disabled AI; local demo proves integration.

## P8 — Release hardening, deployment and portfolio evidence

**Objective:** Complete tested demo with reproducible operational behavior and evidence of architectural ownership.

**Work:** Full API contract audit; APK build; responsive/accessibility polish; structured logging/benchmarks; dependency/version/secret review; migration/role grant/deletion/backup procedures; container and readiness; staging Render/Supabase deployment; CI full checks; deployment runbook. Document actual hosting costs/quotas at deployment time. Build deterministic offline demo fixtures without third-party poster binaries; fetch legitimate real metadata for live demo.

**Likely files:** Dockerfile/CI/deployment settings/runbooks; scripts/demo_seed/cleanup/delete_user/benchmark; frontend integration_test; README architecture/demo; docs/ENGINE_EXAMPLES.md if extracted from normative doc without divergence.

**Acceptance:** Full app path with two accounts; all required checks green; migration and scoped DB role proven; no auth bypass or credentials; password recovery and key-rotation smoke tests complete; no client database access. Release build cannot silently use fixture repositories. LLM disabled still fully functional. Full fixture replay and bounded comparison verification and transaction failure tests pass. Measured500-film engine <100ms target and cached API p95 reported with environment; if target missed, measure/query-optimize rather than invent success. TMDB attribution correct. Backup/restore test on disposable DB; account deletion runbook actually tested.

**Tests:** Entire backend/Flutter suites, PostgreSQL migrations/locking/isolation; build APK; Android login/search/add/choose/reject/watch/rate flows; loading/empty/errors; deployment health/readiness; provider outage,401 refresh,429 and concurrency cases. Existing relevant tests rerun; no redundant giant test expansion solely to increase count.

**Manual:** Staging two accounts isolated; mark watched/reload/rate; verify logs contain only allowed metadata; rotate test JWT key; verify duplicate mutation handling; demonstrate no-match/AI fallback; install APK on device. Capture a short demo: add5–10films ->constraint request ->one pick ->Why ->temporary rejection ->replacement ->completion/rating ->bounded comparison evidence and complete test-fixture replay.

**Deferred:** Public wide launch, notifications, imports, rewatches, streaming availability, cloud NLP and ML training. Broader launch first needs self-service deletion/export and operational review, not a branding update.

## Portfolio explanation checklist

Each student must explain without Claude present:

1. Candidate filtering versus scoring, and why runtime is hard while unknown traits are soft.
2. All six component formulas, missing-data behavior and two worked totals.
3. Why temporary rejection isn't dislike and how a rating edit avoids duplicate learning.
4. Why accept isn't watched, and how DB locks/idempotency prevent duplicate history.
5. JWT verification versus ownership, and the two-account test.
6. LLM schema validity versus semantic validity, plus time-parser precedence and explicit Save/Pick.
7. Full deterministic fixture replay versus bounded historical comparison evidence, and config versioning.

If the team cannot explain a subsystem, the next milestone is understanding and simplifying it—not adding more features.

## Gate ownership and first action

Both students review the baseline now. This is a plan, not an application completion claim. Start with FIRST_CLAUDE_PROMPT. P0 requires no TMDB/Auth/model keys. Keep each milestone inspectable and stop after its report. External publishing requires a separate explicit deployment instruction.

## Mandatory one-choice release gates

Watchlists of20/100/500 films produce one actionable Tonight card. First new-day flow asks desired experience and optional time; existing pick persists on reopen. Mood/down and desired effect are separate. Already seen never claims tonight completion. Third rejection pauses, explicit continuation gives one, no carousel/swipe feed. Core functional suite passes with zero reviewed traits. Recommendation evidence retains <=10 films total and no candidate table. GET me never writes; POST bootstrap naturally converges. No new planning documents are required before starting P0.
