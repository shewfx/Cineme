# Deployment: hosted web/PWA

```
local   Flutter (Android / web)  ->  FastAPI on :8000   ->  Docker PostgreSQL
hosted  Flutter Web/PWA (CDN)    ->  FastAPI on Vercel  ->  Neon PostgreSQL      (same origin)
        identity: Supabase Auth     movie data: TMDB (backend only)
```

Decision record: [ADR 009](adr/009-hosted-web-pwa-on-vercel-and-neon.md). Production URL: https://cineme-theta.vercel.app (Vercel Hobby, Neon Free; no billing information was required). Provider limits change, so check the Vercel and Neon pricing pages before relying on them.

## Environment variables (names only)

Set these in the Vercel project, **Production only** (Settings > Environment Variables). Never commit values.

| Name | Value |
|---|---|
| `ENVIRONMENT` | `production` |
| `LOG_LEVEL` | `INFO` |
| `DATABASE_URL` | Neon **pooled** URL, `postgresql+psycopg://...-pooler.../neondb?sslmode=require` |
| `DATABASE_POOL_MODE` | `serverless` |
| `SUPABASE_URL`, `SUPABASE_JWT_ISSUER` (= URL + `/auth/v1`), `SUPABASE_PUBLISHABLE_KEY` | from the Supabase project (the publishable key is public) |
| `TMDB_READ_ACCESS_TOKEN` | TMDB v4 read token (backend only; mark sensitive) |

`DATABASE_MIGRATION_URL` (the Neon **direct** URL) is only needed on the machine that runs migrations; it is not set on Vercel. Neon's strings start with `postgres://`: replace the scheme with `postgresql+psycopg://` and drop `channel_binding=...`. No Supabase secret or service-role key exists anywhere. Flutter build-time values (all public): `API_BASE_URL=same-origin`, `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`.

When setting values from Windows PowerShell 5.1, do not pipe them straight to the CLI: the pipe adds a UTF-8 byte-order mark, and settings validation then fails. Feed `vercel env add NAME production < file` from a BOM-free file, or use the dashboard.

## Migrations (explicit, never on request)

```powershell
cd backend
$env:DATABASE_MIGRATION_URL = "<Neon direct URL>"     # this session only
uv run python scripts/migrate_hosted.py               # dry run: host, database, role, server, current, head
uv run python scripts/migrate_hosted.py --apply       # upgrade to head and confirm
```

Check that the printed host and database are the intended project before `--apply`. The hosted database was provisioned empty and brought to `0004` this way. `/readyz` reports `ready` only when the database is at the code's head. Run migrations **before** deploying code that needs them.

## Deploy

```powershell
# 1. Build the web bundle with public configuration, then scan it
cd frontend
$sourceCommit = git rev-parse --short HEAD
flutter build web --release --dart-define=API_BASE_URL=same-origin --dart-define=SUPABASE_URL=<url> --dart-define=SUPABASE_PUBLISHABLE_KEY=<publishable key> --dart-define=SOURCE_COMMIT=$sourceCommit
python ../infra/check_web_bundle.py build/web

# 2. Copy it next to the API and deploy (the folder is git-ignored)
Copy-Item build/web/* ../backend/public -Recurse -Force
cd ../backend
npx vercel@62.2.0 deploy --prod
```

The app version displayed in About comes from package metadata generated from
`frontend/pubspec.yaml`; web bundles include Flutter's generated `version.json`.
The `SOURCE_COMMIT` define records the short source SHA used for this web build.

First time only: `npx vercel@62.2.0 login`, then `npx vercel@62.2.0 link --project cineme` in `backend/`. Afterwards verify `/healthz` (ok), `/readyz` (ready), `/api/v1/me` (401 envelope), then sign in on the site.

## Rollback

Application: Vercel keeps earlier deployments; `npx vercel rollback` (or Promote in the dashboard) restores one immediately. Database: treat migrations as forward-only. Deploy code that tolerates both the old and the new schema, run the migration, then deploy; if a migration was wrong, write a new corrective migration instead of downgrading production. Neon keeps point-in-time history for a limited window on the free plan; check the current limit before depending on it.

## Supabase (Authentication > URL Configuration)

- **Site URL:** `https://cineme-theta.vercel.app`
- **Redirect URLs:** add `https://cineme-theta.vercel.app/**` (keep any local entries you use for development).

Email-confirmation links open the site. The app does not read tokens from the address bar, so after confirming you sign in normally. For a custom domain later, add its URL here and attach the domain in Vercel; the build needs no change (`same-origin`).

## Git integration

The Vercel project is **not** connected to the GitHub repository: `vercel link` connects it by default, and a Git-triggered build runs from the repository root (no FastAPI entrypoint there), so pushes and pull requests would show a failing Vercel check and a merge could attempt an unintended production build. It was disconnected with `npx vercel git disconnect`. Deploys are the explicit CLI steps above; do not reconnect it unless the project's Root Directory and a Flutter build step are set up first.

## Previews

Environment variables exist for Production only, so a preview deployment of the API has no database or TMDB credentials and fails closed (`/readyz` not ready). Previews never run migrations or reach production data. If preview databases are wanted later, use a Neon branch per preview with Preview-scoped variables.

## Install on iPhone (Add to Home Screen)

1. Open https://cineme-theta.vercel.app in **Safari**.
2. Tap **Share**.
3. Tap **Add to Home Screen**, then **Add**.
4. Open **Cinemé** from the Home Screen. It launches standalone (no Safari bars). iOS lays the page out inside its safe area, clear of the notch and home indicator, and the floating navigation sits 20 px above the page's bottom edge.

On Android Chrome: menu > **Install app**. The PWA needs a connection (sign-in, search and picks are online); there is no offline mode and API responses are never cached.

## Viewport and touch coordinates (iOS)

`frontend/web/index.html` declares the viewport as exactly `width=device-width, initial-scale=1.0, maximum-scale=5.0`. Flutter's web engine rewrites that tag at startup and never uses the full-screen "cover" fit (it does not read the iOS safe-area insets, so `MediaQuery.padding` is 0 on web). An earlier version of the page asked for the cover fit; on iOS the engine's rewrite then changed the viewport geometry *after* the engine had measured it, with no resize event, so the painted layer and the touch coordinates disagreed (touches landed visibly off) until a resize (opening Search and the on-screen keyboard) made the engine measure again. Declaring what the engine will use removes the startup change. `infra/check_web_bundle.py` fails the build if the meta tag drifts or the cover fit returns. Do not add Y offsets, bigger hit boxes or transforms to compensate.

## Known limits

The runtime database role is the Neon owner (no least-privilege role yet). Free-tier compute suspends when idle, so the first request after a quiet period is slower. The Flutter web build is larger than a typical website (CanvasKit); the browser caches it, no service worker does. TMDB poster images are loaded by the browser from TMDB's CDN (the documented exception); the CDN only sends CORS headers when the request carries an `Origin`, which Flutter's loader does.
