# Tooling and Windows commands

All commands are PowerShell from the repository root unless noted. No `make` or Bash required.

## Recorded toolchain (P0, 2026-10-02)

| Tool | Version | Pinned where |
|---|---|---|
| Python | 3.12 (CPython 3.12.11 via uv) | `backend/.python-version`, `requires-python` |
| uv | 0.12.19 | CI `setup-uv` input |
| Flutter / Dart | 3.47.5 stable / 3.13.4 | CI `flutter-action` input, `pubspec.yaml` SDK constraint |
| Android SDK | platform 36 / build-tools 36.0.0 | local machine only |
| JDK | Temurin 21.0.11 on PATH; Flutter uses Android Studio JBR | local machine only |
| Docker / Compose | 29.8.0 / v5.5.1 | local machine only |
| PostgreSQL | 16 (`postgres:16-alpine`) | `infra/compose.yaml` |

Locked application packages: FastAPI 0.142.2, Starlette 1.7.0, Pydantic 2.13.5, Uvicorn 0.54.0; dev pytest 9.1.1, httpx 0.28.1, ruff 0.16.10, mypy 2.4.0 (`backend/uv.lock`). flutter_riverpod 3.4.3, go_router 18.0.2 (`frontend/pubspec.lock`).

## Backend

From P2 the backend needs PostgreSQL and the Supabase Auth dev project. Copy `backend/.env.example` to `backend/.env` (git-ignored) and fill it: `DATABASE_URL` and `TEST_DATABASE_URL` use the password from `infra/.env`; `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` and `SUPABASE_JWT_ISSUER` (= `SUPABASE_URL` + `/auth/v1`) come from the Supabase dashboard. Never use a secret/service-role key. The Supabase project must sign access tokens with an asymmetric ES256 key (check `https://<ref>.supabase.co/auth/v1/.well-known/jwks.json`) and require email confirmation.

```powershell
cd backend
uv sync                                                  # .venv from uv.lock
uv run --env-file .env alembic upgrade head              # schema "cineme" (migration 0001)
uv run --env-file .env uvicorn app.main:build_app --factory --host 0.0.0.0 --port 8000
Invoke-RestMethod http://127.0.0.1:8000/healthz          # -> status ok (process only)
Invoke-RestMethod http://127.0.0.1:8000/readyz           # -> status ready (DB + migration head)
```

Binding `0.0.0.0` lets the Android emulator reach the API at `http://10.0.2.2:8000`. Invalid or missing settings stop startup with an error naming the setting. Migrations are a separate step; the app never migrates on startup.

Checks (PostgreSQL must be running; integration tests create and drop throwaway databases through `TEST_DATABASE_URL` and fail, not skip, without it):

```powershell
cd backend
uv run ruff check .
uv run ruff format --check .
uv run mypy app
uv run --env-file .env pytest            # unit + PostgreSQL integration + migration smoke
uv run pytest -m "not integration"       # unit only, no database
```

## Frontend

```powershell
cd frontend
flutter pub get
flutter emulators --launch <emulator-id>  # or connect a device
flutter run
```

A normal build needs the API and Supabase configuration at build time. Copy `frontend/dart_defines.example.env` to `frontend/dart_defines.env` (git-ignored) and fill it, then:

```powershell
cd frontend
flutter run --dart-define-from-file=dart_defines.env
```

Without that configuration the app shows "This build is not configured" and never falls back to preview data. Sessions are stored with `flutter_secure_storage` (Android Keystore).

The scripted UI preview (P1 fake repositories) is opt-in; a plain build shows no fake data:

```powershell
flutter run --dart-define=CINEME_PREVIEW=true
# or: flutter build apk --debug --dart-define=CINEME_PREVIEW=true; flutter install -d <device-id> --debug
```

Preview mode is not labelled on screen; it is identified by this build flag. All preview data lives in memory and resets when the app restarts. Profile → "Simulate connection errors" (preview build only) makes every fake repository fail so error states can be checked. Optional local posters for the preview go in `frontend/preview_posters/<tmdbId>.jpg` (git-ignored, see that folder's README and ADR 002); without them the designed placeholder is shown.

Checks:

```powershell
cd frontend
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

## Local PostgreSQL

Start Docker Desktop first.

```powershell
Copy-Item infra/.env.example infra/.env   # then edit the local-only password
docker compose --env-file infra/.env -f infra/compose.yaml config --quiet
docker compose --env-file infra/.env -f infra/compose.yaml up -d
docker compose --env-file infra/.env -f infra/compose.yaml ps   # STATUS shows (healthy)
docker compose --env-file infra/.env -f infra/compose.yaml down
```

The port binds to `127.0.0.1` only. P0 creates no tables; schema arrives through Alembic at P2a.

## Low disk space on C:

If `flutter pub get` or Gradle fails with "not enough space on the disk", or `flutter test` hangs with no output (it writes temporary files to `%TEMP%`), redirect caches for the current PowerShell session:

```powershell
$c = 'D:\cineme-tool-cache'
$env:TEMP = "$c\tmp"; $env:TMP = "$c\tmp"; $env:PUB_CACHE = "$c\pub"; $env:GRADLE_USER_HOME = "$c\gradle"
```

## Flutter SDK path with a space

`supabase_flutter` pulls in `objective_c`, whose native-assets build hook runs `dart compile` with the SDK path unquoted. On this machine the SDK is under `C:\Users\Mohammed Shehwaar\flutter`, so `flutter test` and `flutter build` fail with "'C:\Users\Mohammed' is not recognized". Invoke Flutter through the 8.3 short path instead:

```powershell
$f = (New-Object -ComObject Scripting.FileSystemObject).GetFolder("$env:USERPROFILE\flutter").ShortPath
& "$f\bin\flutter.bat" test
```

Moving the SDK to a path without spaces (for example `D:\flutter`) removes the need for this.

## Docker Desktop after a full disk

When C: filled up, Docker Desktop stayed stuck ("Docker Desktop is unable to start") even after space was freed. `docker desktop restart` recovered it; then start PostgreSQL with the compose commands above.
