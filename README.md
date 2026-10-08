<div align="center">

<img src="frontend/assets/branding/cineme-icon.png" alt="Cinemé app icon" width="96">

# Cinemé

**One pick. No scrolling.**

You keep a watchlist. You tell Cinemé what you want from tonight.<br>
It chooses **one** thing from your own list — a film, or the next episode of a show you're watching. Not a feed, not a carousel, not twenty "you might also like" rows.

**[Open the web app →](https://cineme-theta.vercel.app)**

[![CI](https://github.com/shewfx/Cineme/actions/workflows/ci.yml/badge.svg)](https://github.com/shewfx/Cineme/actions/workflows/ci.yml)
&nbsp;Flutter · FastAPI · PostgreSQL · Supabase Auth · TMDB

</div>

---

## The problem

Most movie apps are built to help you browse *more*: endless rows, autoplaying trailers, another page of suggestions. When you already have a list of things you meant to watch, more options make the decision harder, not easier.

Cinemé is built to help you **decide**. The watchlist is the inventory you already trust; tonight's context narrows it; a deterministic ranking picks one title and tells you why.

## How it works

```
 Your watchlist  ──►  Tonight's context  ──►  Deterministic ranking  ──►  One pick
 (films and shows     (what you want, mood,   (explainable scoring)       (a film or the next
  you chose)           time limit)                                          episode, with reasons)
```

- **Watchlist** — films and shows you saved from TMDB search or discovery.
- **Tonight's context** — what you want from the evening (e.g. *exciting*, *comforting*), an optional mood that never decides the pick, and an optional time limit. Or skip the questions and let it pick.
- **Ranking** — a pure, deterministic scoring engine specified in [RECOMMENDATION_ENGINE.md](RECOMMENDATION_ENGINE.md): hard filters first (released, within your time limit, not blocked, not already offered tonight), then weighted components and a fixed tie-break.
- **One pick** — Tonight always exposes exactly one actionable title, even when it ranked hundreds internally.

## Features

**Tonight**
- Exactly one recommendation: a movie, or the next unwatched regular episode of a show or anime on your watchlist.
- A saved *What to watch* preference: **Movies only**, **Movies & shows** or **Shows only**. New and existing accounts start on Movies only.
- Factual reasons and a "Why this film?" / "Why this episode?" breakdown. Reloading never picks again.
- **Watch Tonight** records that you intend to watch it; it does not mark anything watched. **Mark watched** is a separate, deliberate action — for an episode it also advances your progress.
- **Not this one?** opens a sheet with a single **Reason** dropdown. Choosing a reason never submits; **Show another** gives one replacement, and **Stop for tonight** needs no reason. Asking for another is temporary, never a dislike, and after three passes Tonight pauses for a context review instead of re-rolling.
- Continuity: a show you have been actively watching gets a bounded priority bonus that fades once it has been idle for 21 days.
- An honest "nothing fits" (with counts) instead of silently relaxing your time limit or recommending something outside your watchlist.

**Watchlist and discovery**
- Movie search, plus **Trending this week**, **Popular releases this month** and **Popular releases this year**.
- Show search (anime included) and **Trending shows this week**.
- Filter the watchlist by **All**, **Movies only** or **Shows only**; list or poster grid with sorting, remembered on the device.
- Remove with **Undo** (swipe a row or long-press a poster).
- Films that aren't released yet can be saved and are labelled; they become eligible for Tonight once released.

**Details**
- Movie and show details over a blurred backdrop of the title's own poster.
- **Where to watch** for your streaming region (JustWatch data via TMDB), on details pages and on Tonight's card. Providers use one shared priority order; the first few are shown and the rest expand on demand. For shows this describes the show as a whole, never a promise about a particular episode.
- Show progress ("Last watched: Season 1, Episode 4") with **Set my progress** to correct it.

**History and account**
- Star ratings (1–5) for watched movies, editable later; an edit replaces the earlier rating rather than adding to it.
- History of watched films and a separate **Episodes** history.
- **Never recommend** blocks for films and shows, reversible from Profile.
- New-account onboarding: a short welcome and an optional step to add a few films (with weekly trending). Skip and Continue are always available.
- Swipe between the main tabs (Tonight → Watchlist → History → Profile).

### Anime

Anime is supported through TMDB's TV catalogue, like any other show. Cinemé follows TMDB's standard season and episode order for regular seasons. There is no anime-specific episode ordering, and specials (season 0) are not included, so some anime may be numbered differently from where you watch them.

## Releases

Merged code, the hosted web app and the Android APK are versioned independently and are not always at the same version.

| Channel | Version | Notes |
|---|---|---|
| Web / PWA — [cineme-theta.vercel.app](https://cineme-theta.vercel.app) | 1.2.0+5 | Onboarding, discovery, and shows/anime |
| Android APK | 1.2.1+6 | Replacement build; sign-in confirmed on a device by the maintainer. Distributed directly — there is no public download link yet |
| `main` | 1.2.1+6 | Adds the Android release-target guard (PR #17); no web-facing changes over 1.2.0+5 |

1.2.1 is an Android release fix. The release script ([scripts/build_release_apk.ps1](scripts/build_release_apk.ps1)) forces the production API URL into Android release builds, then inspects every packaged Flutter library. The release fails, and no APK is copied out for distribution, unless each library contains the production API target and none contains a loopback (`localhost`, `127.x`, `10.0.2.2`, …) or `same-origin` target.

There are no GitHub releases or tags for 1.2.x yet. See [CHANGELOG.md](CHANGELOG.md) for user-facing changes and [docs/RELEASING.md](docs/RELEASING.md) for the versioning policy.

## Product principles

These rules come from [PROJECT_SPEC.md](PROJECT_SPEC.md) and constrain every change:

- **Exactly one actionable pick for Tonight.** No grid, no adjacent alternatives, no swipe-to-reroll.
- **The watchlist is inventory, not taste.** Adding a title is not a signal that you like it.
- **"Not tonight" is temporary.** Rejecting tonight's pick is not a permanent dislike; *never recommend* is a separate, reversible block.
- **Hard constraints are never silently relaxed.** If nothing fits your time limit, you get an honest "no match", not something from outside your rules or your watchlist.
- **Accepting is not watching.** Marking something watched is deliberate; a rating is long-term evidence.
- **Deterministic and explainable.** The same inputs give the same pick, with reasons you can read.
- **AI does not choose what you watch** and never invents facts. Unknown metadata stays unknown.

## Recommendation philosophy

Cinemé is intentionally not a thin LLM wrapper. The engine ranks only titles already in your watchlist, using structured inputs: your stated intent for tonight, runtime and genre metadata, your preferences, your viewing history and earlier offers. Every component and weight is specified up front, and the scorer has no network, database, clock or model access — inputs are passed in explicitly, so a pick can be reproduced and tested. Shows enter the same ranking as next-episode candidates ([ADR 011](docs/adr/011-shows-and-anime-next-episode.md)).

If a language model is added (an optional local adapter is planned), its only job is to turn a sentence like *"something light, I'm tired, under two hours"* into a typed proposal that you review. It cannot select a title, change your preferences or apply anything on its own, and the app works fully with it switched off.

## Architecture

```
       ┌──────────────────────────────────┐
       │ Flutter app (Android + Web/PWA)  │
       └─────┬───────────────────┬────────┘
   sign-in,  │                   │  REST + JWT
   session   │                   │
             ▼                   ▼
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
- **The TMDB credential is backend-only.** It never ships in the app. Metadata is cached in PostgreSQL so a saved watchlist keeps working during a TMDB outage.
- Mutations use idempotency keys so a retried request never applies twice.
- **Hosting:** the web build and the API are served from one Vercel project, backed by Neon PostgreSQL. The web build uses `API_BASE_URL=same-origin`, so it calls the API on whatever origin served it. Android builds use the absolute production API URL instead.

Details: [ARCHITECTURE.md](ARCHITECTURE.md), [DATA_MODEL.md](DATA_MODEL.md), [API_CONTRACT.md](API_CONTRACT.md).

## Tech stack

| Layer | Technology |
|---|---|
| App | Flutter / Dart, Riverpod, go_router, Dio, supabase_flutter, flutter_secure_storage |
| API | Python 3.12, FastAPI, Pydantic, HTTPX, PyJWT |
| Data | PostgreSQL 16 locally (Neon in production), SQLAlchemy 2, psycopg 3, Alembic |
| Identity | Supabase Auth (ES256 JWTs) |
| Metadata | TMDB API; streaming availability from JustWatch via TMDB |
| Hosting | Vercel (web + API), Neon (PostgreSQL) |
| Tooling | uv, Ruff, mypy, pytest, Docker Compose (local PostgreSQL), GitHub Actions |

## Running locally

Commands are PowerShell on Windows; full details and troubleshooting are in [docs/TOOLING.md](docs/TOOLING.md).

### Prerequisites

- Python 3.12 via [uv](https://docs.astral.sh/uv/)
- Flutter (stable; see [docs/TOOLING.md](docs/TOOLING.md) for the recorded version) with the Android SDK and an emulator or device, or Chrome for web
- Docker Desktop (local PostgreSQL)
- Your own **Supabase** project (email auth, ES256 signing keys) and a **TMDB** API Read Access Token

### 1. PostgreSQL

```powershell
Copy-Item infra/.env.example infra/.env        # set a local-only password
docker compose --env-file infra/.env -f infra/compose.yaml up -d
```

The database binds to `127.0.0.1` only.

### 2. Backend

```powershell
Copy-Item backend/.env.example backend/.env    # fill in locally; git-ignored
cd backend
uv sync
uv run --env-file .env alembic upgrade head    # local database only
uv run --env-file .env uvicorn app.main:build_app --factory --host 0.0.0.0 --port 8000
```

`backend/.env` holds placeholders until you fill it in, for example:

```dotenv
DATABASE_URL=postgresql+psycopg://cineme:<local-password>@127.0.0.1:5432/cineme
SUPABASE_URL=https://<project-ref>.supabase.co
SUPABASE_PUBLISHABLE_KEY=sb_publishable_<placeholder>
SUPABASE_JWT_ISSUER=https://<project-ref>.supabase.co/auth/v1
TMDB_READ_ACCESS_TOKEN=<tmdb-read-access-token>
TEST_DATABASE_URL=postgresql+psycopg://cineme:<local-password>@127.0.0.1:5432/postgres
```

Never use a Supabase secret/service-role key. Startup fails with a clear message if a setting is missing, and the app never migrates on startup — run `alembic upgrade head` again after pulling new migrations.

Check it: `Invoke-RestMethod http://127.0.0.1:8000/readyz`

### 3. Flutter app

```powershell
cd frontend
Copy-Item dart_defines.example.env dart_defines.env   # API_BASE_URL, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY
flutter pub get
flutter run --dart-define-from-file=dart_defines.env              # Android emulator or device
flutter run -d chrome --dart-define-from-file=dart_defines.env    # web
```

`API_BASE_URL=http://10.0.2.2:8000` (the example value) reaches the local API from the Android emulator; use `http://127.0.0.1:8000` for local web. Only the public Supabase publishable key goes into the app. Without configuration the app says it is not configured — it never falls back to fake data.

### Preview build (no services needed)

```powershell
cd frontend
flutter run --dart-define=CINEME_PREVIEW=true
```

Scripted in-memory data that shows the designed flow. It never contacts Supabase, the API, PostgreSQL or TMDB.

### Production builds

- **Web:** built with `API_BASE_URL=same-origin`, scanned with `infra/check_web_bundle.py` and deployed with the Vercel CLI. Hosted migrations are a separate, explicit step. See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).
- **Android:** release builds use the absolute production API URL and need a local `frontend/android/key.properties` with its keystore for signing (never committed). [scripts/build_release_apk.ps1](scripts/build_release_apk.ps1) is the maintainer's release script. It assumes the maintainer's local Flutter and cache paths, so adapt it before using it elsewhere. Versioning: [docs/RELEASING.md](docs/RELEASING.md).

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

- **Backend:** pure engine tests with a fixed clock, TMDB adapter tests, and PostgreSQL integration tests for ownership and isolation, idempotent retries, concurrency, constraints and migrations. SQLite is deliberately not used as a stand-in. TMDB is mocked; tests never call the network.
- **App:** widget and repository tests over a fake API and the preview store — loading, empty and error states, account switching without data leaks, Undo, and small screens at 200% text.

## Current limitations

- **Shows:** regular seasons only, in TMDB's standard order; no specials and no alternate (e.g. anime-specific) episode orders. There is no whole-series rating control. Marking an episode watched accepts an optional rating, which is stored but can't be edited afterwards in the app and doesn't affect recommendations; only movie ratings feed the ranking.
- **Where to watch** is display-only regional data from JustWatch via TMDB. For shows it covers the show as a whole, not individual episodes.
- **No natural-language context yet.** Tonight's context is chosen from structured options; the optional local LLM adapter is planned, not built.
- **Online only.** The web app has no offline mode, and API responses are not cached.
- **Android distribution is manual.** There is no Play Store listing and no public APK download yet; iPhone users can add the web app to the Home Screen.
- **Hosting runs on free tiers.** The first request after an idle period can be slow.

## Roadmap

Phases and their gates are defined in [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md); verified results are recorded in [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md), and planned work in [docs/ROADMAP.md](docs/ROADMAP.md).

| Phase | Scope | Status |
|---|---|---|
| P0–P3 | Repository and CI, UX prototype, Supabase auth, TMDB search and persistent watchlist | Complete |
| P4 | Deterministic daily selection with evidence, passes/pause and where-to-watch | Complete |
| P5 | Mark watched, ratings, blocks, History and conservative learning | Complete |
| — | Web/PWA hosting, onboarding and discovery, shows and anime (ADRs 009–011) | Shipped |
| P6 | Structured tonight context and time interpretation | Planned |
| P7 | Optional local LLM context adapter | Planned |
| P8 | Release hardening and portfolio evidence | Planned |

## Repository structure

```
backend/         FastAPI app (app/core, users, movies, series, watchlist, recommendations, viewings), Alembic migrations, tests
frontend/        Flutter app (lib/features/*, lib/core, lib/preview), tests
infra/           Docker Compose for local PostgreSQL, web bundle secret check
scripts/         Android release build script
docs/            Implementation status, tooling, deployment, releasing, series design, ADRs (docs/adr)
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
| [docs/SERIES_DESIGN.md](docs/SERIES_DESIGN.md) | Shows and anime: progress, next episode, continuity |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | Hosted web/PWA: Vercel, Neon, environment names, migrations, rollback, Add to Home Screen |
| [docs/RELEASING.md](docs/RELEASING.md) | Version numbers and build metadata |
| [docs/TOOLING.md](docs/TOOLING.md) | Toolchain, Windows commands, Android build troubleshooting |
| [docs/adr/](docs/adr) | Approved deviations |
| [CHANGELOG.md](CHANGELOG.md) | User-facing changes by version |

If two documents disagree, the conflict is reported and resolved explicitly before the affected behavior is built. Agent instructions live in [CLAUDE.md](CLAUDE.md); the original planning-package notes (baseline decisions, external sources, completion definition) are in [docs/PLANNING_PACKAGE.md](docs/PLANNING_PACKAGE.md).

## Contributing

- Work in a feature branch per phase or task; keep commits scoped.
- Preserve the product invariants and architecture boundaries above; significant deviations need an ADR.
- Formatter, static analysis and tests pass before merge.
- No secrets in Git: `.env` files, `dart_defines.env` and Android signing files stay local; example files hold placeholders only.

## TMDB attribution

This product uses the TMDB API but is not endorsed or certified by TMDB.

Where-to-watch information is provided by [JustWatch](https://www.justwatch.com/) through TMDB and is shown with that attribution.

Movie and show metadata and images are provided by [The Movie Database (TMDB)](https://www.themoviedb.org/) and used under its developer terms for this noncommercial project.

## License

No license has been added yet. Until one is, all rights are reserved by the author.
