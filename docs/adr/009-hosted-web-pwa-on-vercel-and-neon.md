# ADR 009: Hosted web/PWA on one Vercel project with Neon PostgreSQL

Status: accepted by the project owner, 2026-10-03 (deployment task).

## Decision

- **One Vercel project, root directory `backend/`.** FastAPI is the Python function (`backend/index.py` exports `app = build_app()`); the Flutter web build is copied to the git-ignored `backend/public/` and served from the CDN. The app is same-origin (`API_BASE_URL=same-origin`), so there is no CORS configuration, and a custom domain can be attached later without a rebuild.
- **The Flutter build is not done inside Vercel.** It is built locally or in CI (`flutter build web`) and uploaded with `vercel deploy`. Installing Flutter during a Vercel build was rejected as fragile; two separate projects were rejected because they need CORS, two URLs and two sets of origins.
- **Neon PostgreSQL** (free plan) is the hosted database. The runtime uses the pooled (`-pooler`, PgBouncer transaction mode) URL with `DATABASE_POOL_MODE=serverless`; migrations use the direct URL. SQLAlchemy, psycopg and Alembic are unchanged.
- **Serverless engine mode.** The pooler rejects the `options=-c statement_timeout...` startup parameter, so serverless mode applies `SET LOCAL statement_timeout/lock_timeout` at the start of every transaction, disables psycopg prepared statements, keeps a small pool with `pool_pre_ping` and `pool_recycle`, and allows 10 s to connect (a suspended Neon compute wakes slowly). Local development keeps the original pool and startup options.
- **TLS is required in production:** settings reject a production `DATABASE_URL`/`DATABASE_MIGRATION_URL` without `sslmode=require` (or stricter).
- **Migrations are an explicit step**, never run by requests: `backend/scripts/migrate_hosted.py` identifies the target (host, database, role, never the password), shows current and head, refuses localhost/pooled/non-TLS targets, and upgrades only with `--apply`.
- **Previews hold no data credentials.** Production environment variables are set for Production only, so a preview deployment fails closed instead of touching production data or secrets.
- **Session storage on web** uses the Supabase SDK default (browser storage); Android keeps Keystore-backed secure storage.
- **No service worker caching.** The Flutter service worker is the self-unregistering stub; API responses are `Cache-Control: no-store`.

## Why

It is the smallest arrangement that is officially supported, keeps FastAPI, needs no generated output in git, and gives one stable PWA URL.

## Tradeoff

Deploys are driven by the Vercel CLI (or a CI job with a Vercel token) rather than Git integration alone, because the Flutter bundle is not in the repository. The function region is pinned to `iad1` next to Neon in `us-east-1`, which adds latency for users far from the US. Cold starts and a suspended free Neon compute add a one-off delay after idle periods. The app connects as the Neon owner role; a least-privilege runtime role is future hardening.

## Affected contracts

ARCHITECTURE "Configuration and secrets" and "Deployment"; docs/DEPLOYMENT.md; docs/TOOLING.md. No API contract change.

## Validation

Backend tests for production TLS, pool modes, the serverless engine against real PostgreSQL and the Vercel entrypoint; Flutter tests for same-origin configuration, the centred canvas and iPhone safe areas; CI builds the web bundle and scans it for secrets; live checks of `/healthz`, `/readyz`, sign-in, persistence across reload and restart, search, add/remove, and the full Tonight flow against the hosted database.
