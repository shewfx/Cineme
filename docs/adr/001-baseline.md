# ADR 001 — Architecture baseline

Status: accepted, 2026-10-02.

## Decision

The planning package (specification version 1.1) is the architectural baseline: README.md, CRITICAL_REVIEW.md, PROJECT_SPEC.md, ARCHITECTURE.md, DATA_MODEL.md, RECOMMENDATION_ENGINE.md, API_CONTRACT.md, FRONTEND_SPEC.md, DEVELOPMENT_PLAN.md and CLAUDE.md. Authority is by subject as described in README.md.

Concretely: Flutter Android first with Riverpod (no code generation) and go_router; Python 3.12 FastAPI modular monolith with synchronous SQLAlchemy 2/psycopg 3, Alembic and PostgreSQL 16; Supabase Auth with backend JWT verification; backend-only TMDB access; a pure deterministic scorer; optional local Ollama for context proposals only.

## Why

The documents already record the decisions and tradeoffs (ARCHITECTURE.md A01–A11). One reference point lets later ADRs describe deviations precisely.

## Tradeoff

Any change to these contracts needs a new ADR plus updates to the affected authoritative documents, rather than drifting through code.

## P0 implementation notes (not deviations)

- Backend settings use plain Pydantic v2 models read from environment variables; `pydantic-settings` is not added until configuration needs it.
- Dio is not added at P0: there is no HTTP call yet (DEVELOPMENT_PLAN P0 allows deferring it). It arrives with the first API client.
- The Riverpod-injected `AppConfig` (`API_BASE_URL`) is deferred with Dio, since nothing consumes it at P0.

## Affected contracts and validation

None changed. P0 gates are recorded in [docs/IMPLEMENTATION_STATUS.md](../IMPLEMENTATION_STATUS.md).
