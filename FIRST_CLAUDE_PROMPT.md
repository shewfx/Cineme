# First Claude Code prompt

Paste the block below from the repository root after copying this package there.

```text
Implement only Phase P0 — Bootable repository skeleton for Cinemé.

First read CLAUDE.md and every planning document in the repository: README.md, CRITICAL_REVIEW.md, PROJECT_SPEC.md, ARCHITECTURE.md, DATA_MODEL.md, RECOMMENDATION_ENGINE.md, API_CONTRACT.md, FRONTEND_SPEC.md and DEVELOPMENT_PLAN.md. Read any applicable AGENTS.md and approved ADRs. Treat these documents as the architectural baseline.

Inspect the current directory, git status/branch, existing files, Flutter/Dart, Python 3.12, uv, Android tooling and Docker availability. Do not overwrite unrelated work. If the directory is not a git repository, initialize a local repository with main as default branch, then create feature/p0-foundation. If it already is a repository on main/master, create that feature branch; if already on a task branch, keep it. Do not create a remote, commit, push or deploy.

Verify assumptions and identify contradictions before implementing affected behavior. Explain your intended changes, files and validation commands before editing. Routine decisions within the baseline are authorized; proceed without requiring me to approve every file.

Build P0 only:
- backend FastAPI skeleton with validated settings, safe placeholder .env.example, public GET /healthz, its tests, uv-managed dependencies/lockfile, ruff and mypy configuration;
- frontend Flutter Android skeleton with Cinemé app/theme, a minimal Today placeholder shell, Riverpod/go_router/Dio foundations only where needed, and a launch/widget test;
- infra/compose.yaml defining local PostgreSQL 16 with healthcheck and local-only port binding; no application tables or database access yet;
- CI for the checks implemented at P0;
- Windows PowerShell-friendly setup commands, recorded/pinned tool versions, repository .gitignore and architecture baseline note in docs/adr;
- a linked phase progress file recording only verified work.

Do not implement authentication, tables/migrations, TMDB calls, watchlist behavior, scoring, feedback, context parsing, AI integration or deployment. Do not build the complete app. Do not add empty layers just to mimic the planned folder tree. Do not request provider credentials for this phase.

Acceptance: backend health endpoint and test work; Flutter placeholder launches with its widget test; formatter/linter/type/static tests pass; compose configuration validates; no secrets or placeholder fake production behavior. If a prerequisite is missing, report the exact block, finish independent authorized work, and mark the affected acceptance criterion unverified rather than claiming completion.

Run all P0 checks in DEVELOPMENT_PLAN.md. Report modified files, actual command results, manual checks performed, remaining blockers and any proposed deviations. Stop after P0. Do not start P1, commit or publish anything.
```
