# Cinemé — Claude Code repository instructions

You are implementing an existing architecture, not designing a different product. This repository is a portfolio app that chooses ONE movie from a user's own watchlist. Small, correct, understandable changes are the goal.

## Before each task

1. Read README.md, CRITICAL_REVIEW.md, PROJECT_SPEC.md, ARCHITECTURE.md, DATA_MODEL.md, RECOMMENDATION_ENGINE.md, API_CONTRACT.md, FRONTEND_SPEC.md and DEVELOPMENT_PLAN.md. Read approved docs/adr changes. Reuse current knowledge within a task; reread relevant sections when contracts change.
2. Inspect repository state, available tools, lockfiles and current tests. Read any applicable AGENTS.md. Protect unrelated/uncommitted work.
3. Identify the authorized phase or task. If absent, work only on the next incomplete phase/submilestone, starting P0; P1a/P2a etc are separately gated, not permission to implement all of auth at once. Do not implement later phases early.
4. Explain intended files, behavior, validation and any genuine blockers before editing. For routine implementation within these documents, proceed after explaining; do not turn every edit into a confirmation request.
5. If authoritative documents contradict one another or a necessary architecture deviation is unresolved, report the exact conflict and propose a concrete resolution before implementing that affected behavior. Continue independent authorized work where possible.

## Architecture guardrails

- Flutter Android first; feature-first repositories/controllers/widgets with Riverpod and go_router.
- Python3.12/FastAPI modular monolith, SQLAlchemy2/psycopg3 sync database, Alembic and PostgreSQL.
- Supabase handles identity. FastAPI verifies JWTs and scopes every private operation. Never accept user_id from client as identity.
- TMDB data calls stay in backend; no secrets in frontend. Poster CDN is the documented exception.
- Ranking is the pure deterministic engine from RECOMMENDATION_ENGINE. Never replace it with an LLM-selected movie, arbitrary randomness, embeddings or hidden heuristic.
- No network, database access, clock lookup or model call in scorer. Pass inputs/time/config explicitly.
- Do not infer pace/complexity/heaviness from genre or generated prose. Unknown traits remain unknown. Curated traits require provenance/version and are optional enrichment; no dataset/rows must remain fully functional.
- AI only proposes typed context in V1. It cannot mutate user preferences, history, selection or weights. User must explicitly Save/Pick using the reviewed proposal; parsing never applies changes. current_mood cannot infer desired_experience or select comedy from sadness. Explanation templates remain deterministic.
- Preserve feature boundaries. Avoid circular imports, universal CRUD layers and “enterprise” abstractions.
- No Redis, queue, microservices, nightly jobs, public chat, stream playback, imports, collaborative filtering or future-scope feature unless explicitly authorized as a scope change.

## Product guardrails

- One current daily pick; context-first initial flow, read/reload does not generate another. Tonight exposes one actionable film even when the engine ranks500. No carousel/grid/adjacent alternatives or swipe re-roll.
- Hard runtime/block constraints cannot be silently relaxed.
- Not tonight is temporary; never recommend is a reversible explicit block; watched rating is long-term evidence.
- Accept is not watched. Mark watched must be deliberate, idempotent and atomic with history/watchlist updates.
- Rating edits replace prior evidence; never double-count.
- No-match is an honest result, not permission to recommend outside the watchlist. Pick another may atomically record scoped feedback and select ONE replacement; third rejection pauses for context review. Just give me another is temporary, never dislike.
- No fake movie/server success fallback in normal builds.
- Preserve concurrent-write behavior, session versions, idempotency replay and user ownership checks.

## Dependencies, secrets and environment

Introduce only justified dependencies needed by the current phase. List purpose and alternatives rejected before adding any dependency not already selected. Resolve compatible versions, pin toolchain, commit lockfiles; do not opportunistically upgrade major versions.

Never commit .env, tokens, passwords, database URLs with credentials, service-role keys, private JWT signing keys or provider cookies. Example files contain placeholders only. Never print secrets in logs/terminal/reports. Supabase publishable key is public but project settings still belong in configuration, not scattered widgets. Production may never contain a runtime auth bypass.

Use Windows-friendly documented commands. Prefer uv for Python environment/locking; Docker Compose for PostgreSQL; Flutter CLI for Android. Do not assume Windows has make or a Bash environment. If required tooling is missing, report exact prerequisite and work that can still be done. No dangerous cleanup or overwriting unrelated projects.

## Database and API changes

Write Alembic migrations, not create_all() production setup. Preserve histories and bounded winner evidence. Add schema at its feature milestone; P2 has only User/UserPreferences. Run real PostgreSQL integration tests for locking, JSONB and constraints. SQLite cannot stand in for these.

Implement API_CONTRACT request/response/error shapes, nullability, status codes and safe retries exactly. Update OpenAPI snapshot and client DTOs together for an approved contract change. Profile bootstrap is explicit POST me/bootstrap, naturally idempotent and exempt from the later generic key ledger. GET me is read-only. Keep private mutations out of GET; shared metadata-cache reads are the only documented cache side effect. Do not generate picks in GET.

Lock private mutations in documented order, avoid network in transactions, recheck idempotency/version after lock. Do not hide a partial mutation behind a success response. Persist bounded winner/config/context evidence and up to nine runners-up; no recommendation_scores table/full production RankingInput archive. Complete fixture replay remains required in tests; production comparison evidence does not claim full historical-set replay.

## Validation and reporting

After changes run the phase's relevant formatter, static analysis and tests. When backend code exists: `uv run ruff check .`, `uv run ruff format --check .`, `uv run mypy app`, `uv run pytest`. When Flutter exists: `dart format --output=none --set-exit-if-changed lib test`, `flutter analyze`, `flutter test`. Integration commands and required PostgreSQL environment are documented in repo tooling instructions. Use scoped checks during work; final milestone runs all implemented gates.

Tests must verify meaningful behavior, especially scope/isolation/filtering/transitions, not merely restate implementation. Do not weaken assertions, skip security tests, swallow exceptions or delete failing tests to make green output. Network provider calls use mocks in CI. Explicitly report any command not run, failure, skipped test or environment block; never claim success without evidence.

Final task report must include:

- phase/task completed and concrete behavior;
- modified files grouped by purpose;
- validation commands and actual results;
- manual verification steps and outcomes where performed;
- blockers/known limits/deviations;
- next authorized milestone, then stop.

Maintain a phase status record in DEVELOPMENT_PLAN or a linked implementation progress file, distinguishing completed from planned work. Do not mark a phase done if required gates failed or were not run; mark blocked/partial instead.

## Git and architectural decisions

Inspect branch and status before edits. If in a git repository on main/master, create a scoped feature branch before changes unless current instruction explicitly requires that branch. If already on a task branch, keep it. If no git repository exists, do not invent remotes; initialize only when requested in the current task.

Keep commits scoped; do not commit unrelated work or credentials. Only commit when requested by the task/user; never auto-push, merge or deploy. An implementation task is not permission to publish.

Significant approved deviations are documented in `docs/adr/NNN-title.md` with Decision / Why / Tradeoff, affected contracts and validation. Update the relevant authoritative docs. Do not silently change architecture because a package example is convenient. Routine file naming or widget composition does not need an ADR.

## Stop conditions

Complete only the authorized milestone. Run its gates, report results and stop. Do not continue to the next phase because there is remaining context or time. A missing external API key does not justify replacing the architecture with an unofficial endpoint. A failing optional LLM does not justify weakening deterministic ranking.
