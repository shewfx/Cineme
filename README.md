<div align="center">

# Cinemé

**One movie. No scrolling.**

You keep a watchlist. You tell Cinemé what you want from tonight.<br>
It chooses **one** film from your own list — not a feed, not a carousel, not twenty "you might also like" rows.

[![CI](https://github.com/shewfx/Cineme/actions/workflows/ci.yml/badge.svg)](https://github.com/shewfx/Cineme/actions/workflows/ci.yml)
&nbsp;Flutter · FastAPI · PostgreSQL · Supabase Auth · TMDB

</div>

---

> **Status:** in active development. Search, a persistent per-user watchlist and the deterministic Tonight pick work end to end against real services. History, ratings and blocks come next (P5). See [Roadmap](#roadmap).

## The problem

Most movie apps are built to help you browse *more*: endless rows, autoplaying trailers, another page of suggestions. When you already have a list of films you meant to watch, more options make the decision harder, not easier.

Cinemé is built to help you **decide**. The watchlist is the inventory you already trust; tonight's context narrows it; a deterministic ranking picks one film and tells you why.

## How it works

```
 Your watchlist  ──►  Tonight's context  ──►  Deterministic ranking  ──►  One movie
 (films you chose)    (mood, time, genres)    (explainable scoring)       (with reasons)
     available              available               available (P4)           available (P4)
```

- **Watchlist** — search TMDB and save films you might watch. Implemented.
- **Tonight's context** — what you want from the evening (e.g. *exciting*, *comforting*), an optional mood that never decides the pick, and an optional time limit.
- **Ranking** — a pure, deterministic scoring engine specified in [RECOMMENDATION_ENGINE.md](RECOMMENDATION_ENGINE.md): hard filters first (released, within your time limit, not already offered tonight), then six weighted components and a fixed tie-break.
- **One movie** — Tonight always exposes exactly one actionable film, even when it ranked hundreds internally.

## What works today

| Area | Capability |
|---|---|
| Accounts | Supabase email/password sign-up and sign-in, sessions in Android secure storage (browser storage on web), explicit profile bootstrap |
| Backend | FastAPI verifies Supabase JWTs and scopes every private read and write to the caller |
| Search | TMDB movie search through the backend, with years, genres and real poster artwork |
| Watchlist | Persistent per-user watchlist in PostgreSQL: add, duplicate detection, pagination, remove with Undo |
| Watchlist views | List or poster grid and a Sort control (recently added, oldest, title, release year, runtime; sorted by the server so paging stays correct), all remembered on the device; swipe a row to remove, long-press a poster for actions |
| Upcoming films | Upcoming or undated films can be saved and are labelled "Not released yet"; they will not be eligible for Tonight until released |
| Resilience | The saved watchlist keeps working while TMDB is down; failures are shown, never replaced with fake data |
| Isolation | Users can never see or change each other's watchlists (covered by PostgreSQL integration tests) |
| Tonight setup | A short branded opening, then three compact selectors (what you want, optional feeling, optional time) in bottom sheets, or **Skip, just pick something** for one pick with no questions (it uses the explicit Surprise me intent) |
| Tonight | One pick from your watchlist with factual reasons and a “Why this film?” breakdown; reloading never picks again; “Not feeling it” gives one replacement (or records “Already watched”), and after three passes it pauses instead of re-rolling; an honest “nothing fits” with counts instead of relaxing your limits |
| Where to watch | “Available on” for tonight's film in your streaming region (JustWatch data via TMDB), display-only |
| Web / PWA | The same Flutter app as an installable web app (Add to Home Screen on iPhone): https://cineme-theta.vercel.app, hosted on Vercel with Neon PostgreSQL; wide browsers get a centred phone-width canvas. See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) |
| Preview mode | An opt-in build with scripted, in-memory data that shows the full designed flow — including Tonight, feedback and history — without contacting any service |

Not there yet: “Mark watched”, ratings, never-recommend blocks, the History tab and natural-language context. Those exist only in the preview build for now.

## Product principles

These rules come from [PROJECT_SPEC.md](PROJECT_SPEC.md) and constrain every phase:

- **Exactly one actionable movie for Tonight.** No grid, no adjacent alternatives, no swipe-to-reroll.
- **The watchlist is inventory, not taste.** Adding a film is not a signal that you like it.
- **"Not tonight" is temporary.** Rejecting tonight's pick is not a permanent dislike; *never recommend* is a separate, reversible block.
- **Hard constraints are never silently relaxed.** If nothing fits your time limit, you get an honest "no match", not a film from outside your rules or your watchlist.
- **Accepting is not watching.** Marking a film watched is deliberate; a rating is long-term evidence.
- **Deterministic and explainable.** The same inputs give the same pick, with reasons you can read.
- **AI does not choose the movie** and never invents movie facts. Unknown metadata stays unknown.

## Recommendation philosophy

Cinemé is intentionally not a thin LLM wrapper. The planned engine ranks only films already in your watchlist, using structured inputs: your stated intent for tonight, runtime and genre metadata, your preferences, your viewing history and earlier offers. Every component and weight is specified up front, and the scorer has no network, database, clock or model access — inputs are passed in explicitly, so a pick can be reproduced and tested.

If a language model is added (an optional local adapter is planned for P7), its only job is to turn a sentence like *"something light, I'm tired, under two hours"* into a typed proposal that you review. It cannot select a film, change your preferences or apply anything on its own, and the app works fully with it switched off.

## Screenshots

<!--
  No screenshots are committed yet. Add real captures from a device or emulator:
    docs/screenshots/search.png      Search with TMDB results
    docs/screenshots/watchlist.png   Watchlist, list view
    docs/screenshots/posters.png     Watchlist, poster view
    docs/screenshots/tonight.png     Tonight pick (after P4; until then, preview build only)
  Do not commit TMDB poster files on their own; app screenshots showing posters are fine.
-->

_Screenshots will be added here (`docs/screenshots/`)._

## Architecture

```
            ┌────────────────────────┐
            │  Flutter (Android app) │
            └─────┬────────────┬─────┘
     sign-in,     │            │  REST + JWT
     session      │            │
                  ▼            ▼
      ┌────────────────┐   ┌──────────────────────────┐        ┌──────────────┐
      │ Supabase Auth  │   │   FastAPI (modular        │ ─────► │   TMDB API   │
      │  (identity)    │◄──│   monolith)               │ token  │  (metadata)  │
      └────────────────┘   │  verifies JWTs, owns      │ stays  └──────────────┘
         JWKS public keys  │  authorization + logic    │ here
                           └────────────┬─────────────┘
                                        ▼
                              ┌──────────────────┐
                              │   PostgreSQL     │
                              │ (SQLAlchemy +    │
                              │  Alembic)        │
                              └──────────────────┘

   Poster images load directly from TMDB's image CDN (the one documented exception).
```

- **Flutter never talks to the application database.** All private data goes through the FastAPI API.
- **Supabase provides identity only.** The app signs in with Supabase; FastAPI verifies the access token against Supabase's public signing keys and takes the user's identity from it — never from a client-supplied user id.
- **FastAPI owns authorization and product logic.** Every private operation is scoped to the caller; another user's resource is a plain 404.
- **The TMDB credential is backend-only.** It never ships in the Android build. Movie metadata is cached in PostgreSQL so a saved watchlist keeps working during a TMDB outage.
- Mutations use idempotency keys so a retried request never applies twice.

Details: [ARCHITECTURE.md](ARCHITECTURE.md), [DATA_MODEL.md](DATA_MODEL.md), [API_CONTRACT.md](API_CONTRACT.md).

## Tech stack

| Layer | Technology |
|---|---|
| App | Flutter / Dart, Riverpod, go_router, Dio, supabase_flutter, flutter_secure_storage |
| API | Python 3.12, FastAPI, Pydantic, HTTPX, PyJWT |
| Data | PostgreSQL 16, SQLAlchemy 2, psycopg 3, Alembic |
| Identity | Supabase Auth (ES256 JWTs) |
| Metadata | TMDB API |
| Tooling | uv, Ruff, mypy, pytest, Docker Compose (local PostgreSQL), GitHub Actions |

## Roadmap

Phases and their gates are defined in [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md); verified results are recorded in [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md).

| Phase | Scope | Status |
|---|---|---|
| P0 | Bootable repository, toolchain, CI | Complete |
| P1 | Full UX prototype on fake data (Tonight, feedback, inventory, history) | Complete |
| P2 | Supabase auth, profile bootstrap, PostgreSQL foundation | Complete |
| P3 | TMDB search and persistent per-user watchlist | Complete |
| P4 | Deterministic daily selection: the real Tonight pick, with evidence, passes/pause, Already watched and where-to-watch (ADR 006, 007) | Complete |
| P5 | Mark watched, ratings, blocks, History and conservative learning | Planned (next) |
| P6 | Structured tonight context and time interpretation | Planned |
| P7 | Optional local LLM context adapter | Planned |
| P8 | Release hardening, deployment and portfolio evidence | Planned |

## Running locally

Commands are PowerShell on Windows; full details and troubleshooting are in [docs/TOOLING.md](docs/TOOLING.md).

### Prerequisites

- Python 3.12 via [uv](https://docs.astral.sh/uv/) 0.12
- Flutter 3.47 (stable) with the Android SDK and an emulator or device
- Docker Desktop (local PostgreSQL)
- Your own **Supabase** project (email auth, ES256 signing keys) and a **TMDB** API Read Access Token

### 1. PostgreSQL

```powershell
Copy-Item infra/.env.example infra/.env        # set a local-only password
docker compose --env-file infra/.env -f infra/compose.yaml up -d
```

### 2. Backend

```powershell
Copy-Item backend/.env.example backend/.env    # fill in locally; git-ignored
cd backend
uv sync
uv run --env-file .env alembic upgrade head
uv run --env-file .env uvicorn app.main:build_app --factory --host 0.0.0.0 --port 8000
```

`backend/.env` needs `DATABASE_URL`, `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_JWT_ISSUER`, `TMDB_READ_ACCESS_TOKEN` and, for tests, `TEST_DATABASE_URL`. The example file contains placeholders only. Never use a Supabase secret/service-role key. Startup fails with a clear message if a setting is missing.

Check it: `Invoke-RestMethod http://127.0.0.1:8000/readyz`

### 3. Flutter app

```powershell
cd frontend
Copy-Item dart_defines.example.env dart_defines.env   # API_BASE_URL, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY
flutter pub get
flutter run --dart-define-from-file=dart_defines.env
```

`API_BASE_URL=http://10.0.2.2:8000` reaches the local API from the Android emulator. Only the public Supabase publishable key goes into the app. Without configuration the app says it is not configured — it never falls back to fake data.

### Preview build (no services needed)

```powershell
cd frontend
flutter run --dart-define=CINEME_PREVIEW=true
```

Scripted in-memory data that shows the whole designed experience. It never contacts Supabase, the API, PostgreSQL or TMDB.

## Testing

Both suites run in [GitHub Actions](.github/workflows/ci.yml) on every push and pull request, with a real PostgreSQL 16 service for the backend.

```powershell
# backend (PostgreSQL running; integration tests need TEST_DATABASE_URL)
cd backend
uv run ruff check .
uv run ruff format --check .
uv run mypy app
uv run --env-file .env pytest

# app
cd frontend
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

- **Backend:** unit tests (TMDB adapter normalization, timeouts, retries, error mapping) and PostgreSQL integration tests for ownership and isolation, idempotent retries, concurrent adds, database constraints and migrations. SQLite is deliberately not used as a stand-in. TMDB is mocked; tests never call the network.
- **App:** widget and repository tests over a fake API and the preview store — loading, empty and error states, account switching without data leaks, swipe removal and Undo, small screens at 200% text.

## Repository structure

```
backend/         FastAPI app (app/core, app/users, app/movies, app/watchlist), Alembic migrations, tests
frontend/        Flutter app (lib/features/*, lib/core, lib/preview), tests
infra/           Docker Compose for local PostgreSQL
docs/            Implementation status, tooling, architecture decision records (docs/adr)
*.md (root)      Product, architecture, data, API, frontend and engine specifications
```

## Documentation

The root specifications are the source of truth, each for its own subject:

| Document | Authority |
|---|---|
| [PROJECT_SPEC.md](PROJECT_SPEC.md) | Product behavior and invariants |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Boundaries and architecture decisions |
| [DATA_MODEL.md](DATA_MODEL.md) | Relational schema and transaction rules |
| [RECOMMENDATION_ENGINE.md](RECOMMENDATION_ENGINE.md) | Scoring formulas and worked examples |
| [API_CONTRACT.md](API_CONTRACT.md) | Client/server wire contracts |
| [FRONTEND_SPEC.md](FRONTEND_SPEC.md) | Flutter structure and interaction details |
| [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md) | Phases and gates |
| [CRITICAL_REVIEW.md](CRITICAL_REVIEW.md) | Concept risks and decisions taken before specification |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | Hosted web/PWA: Vercel, Neon, environment names, migrations, rollback, Add to Home Screen |
| [docs/adr/](docs/adr) | Approved deviations |

If two documents disagree, the conflict is reported and resolved explicitly before the affected behavior is built. Agent instructions live in [CLAUDE.md](CLAUDE.md); the original planning-package notes (baseline decisions, external sources, completion definition) are in [docs/PLANNING_PACKAGE.md](docs/PLANNING_PACKAGE.md).

## Contributing

- Work in a feature branch per phase or task; keep commits scoped.
- Preserve the product invariants and architecture boundaries above; significant deviations need an ADR.
- Formatter, static analysis and tests pass before merge.
- No secrets in Git: `.env` files and `dart_defines.env` stay local; example files hold placeholders only.

## TMDB attribution

This product uses the TMDB API but is not endorsed or certified by TMDB.

Where-to-watch information is provided by [JustWatch](https://www.justwatch.com/) through TMDB and is shown with that attribution.

Movie metadata and images are provided by [The Movie Database (TMDB)](https://www.themoviedb.org/) and used under its developer terms for this noncommercial project.

## License

No license has been added yet. Until one is, all rights are reserved by the author.
