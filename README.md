# Cinemé — repository planning package

Specification version: 1.1. Prepared 2026-10-02. Status: implementation baseline, not an implemented application.

Copy these files into the repository root, including `CLAUDE.md`. The archive also contains every document. No application source is included. Revision1.1 incorporates the review: bounded comparisons, explicit POST bootstrap, UI before auth, optional traits, and context-first ONE-movie UX. This revises the existing package rather than adding design documents.

## Read order and authority

1. `CRITICAL_REVIEW.md`: concept risks and decisions made before specification.
2. `PROJECT_SPEC.md`: product behavior and numbered invariants.
3. `ARCHITECTURE.md`: boundaries and architecture decisions.
4. `DATA_MODEL.md`: relational schema and transaction rules.
5. `RECOMMENDATION_ENGINE.md`: normative scoring formulas and worked examples.
6. `API_CONTRACT.md`: client/server wire contracts.
7. `FRONTEND_SPEC.md`: Flutter structure and interaction details.
8. `DEVELOPMENT_PLAN.md`: implementation phases and gates.
9. `CLAUDE.md`: instructions Claude Code must obey.
10. `FIRST_CLAUDE_PROMPT.md`: paste this prompt to start Phase 0 only.

`VALIDATION_NOTES.md` records the documentation checks and their limits. It is not evidence of an implemented or tested application.

Authority is by subject, not “last file read.” Product semantics belong to PROJECT_SPEC; mathematical behavior to RECOMMENDATION_ENGINE; schema to DATA_MODEL; wire formats to API_CONTRACT. If these disagree, report the conflict and resolve it explicitly before implementing the affected behavior. Do not silently pick an interpretation.

## Baseline decisions

Flutter Android first; Python 3.12/FastAPI modular monolith; PostgreSQL; SQLAlchemy 2 and Alembic; Supabase Auth; TMDB metadata; Riverpod and go_router. One controlled weighted scorer, confirmed desired experience separate from emotion, optional Ollama context parsing, deterministic explanation templates. Rank up to500 internally, persist winner plus at most nine runners-up, never show a Tonight feed. No Redis, queue, embeddings, agents, custom password service or streaming catalogue.

There are nine implementation phases, P0–P8. Shipping gates are behavioral, not calendar promises. Start at P0; P1 is the fake UI prototype, P2 is minimal auth/persistence in separately gated slices; do not build the whole app in one Claude Code run.

## Source verification

External facts were checked against official documentation. These are implementation references, not permission to change the architecture. Recheck provider contracts when integrating; pin compatible dependency versions in lockfiles at P0.

| Reference | What it establishes |
|---|---|
| [TMDB FAQ](https://developer.themoviedb.org/docs/faq) | Developer/noncommercial use, attribution and commercial licensing distinction |
| [TMDB details](https://developer.themoviedb.org/reference/movie-details) and [search workflow](https://developer.themoviedb.org/docs/search-and-query-for-details) | Search and movie detail calls are separate; fetch details for runtime |
| [TMDB images](https://developer.themoviedb.org/docs/image-basics) and [rate limiting](https://developer.themoviedb.org/docs/rate-limiting) | Image configuration and handling upstream throttling |
| [JustWatch partner documentation](https://apis.justwatch.com/docs/content_partner/) | Partner catalogue/availability integration; this does not establish permission or an OAuth flow for private watchlists |
| [Letterboxd export](https://letterboxd.com/user/exportdata/) and [CSV format](https://letterboxd.com/about/importing-data/) | User-exported files are a plausible later ingestion source; actual export columns must be inspected |
| [Supabase password auth](https://supabase.com/docs/guides/auth/passwords), [JWT keys](https://supabase.com/docs/guides/auth/signing-keys) | Managed authentication and asymmetric JWT verification |
| [Flutter architecture guidance](https://docs.flutter.dev/app-architecture/recommendations) and [Riverpod](https://riverpod.dev/) | Presentation/data separation and manageable async state |
| [Ollama structured outputs](https://docs.ollama.com/capabilities/structured-outputs) | Local schema-constrained generation; provider capabilities are not universal |

## Completion definition

An authenticated user can search, add movies, get one persisted choice, inspect its reasons, reject it with the correct scope, mark it watched, rate it, and see future scores change. The same works with the LLM disabled. A second account cannot read or mutate any private data from the first. A reproducible demo and tests prove these claims.
