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

```powershell
cd backend
uv sync                                   # creates .venv from uv.lock
uv run uvicorn app.main:app --reload      # http://127.0.0.1:8000
Invoke-RestMethod http://127.0.0.1:8000/healthz   # -> status ok
```

Settings come from environment variables (`ENVIRONMENT`, `LOG_LEVEL`); defaults need none. For local overrides copy `backend/.env.example` to `backend/.env` and run `uv run --env-file .env uvicorn app.main:app --reload`. Invalid values stop startup with an error naming the setting.

Checks:

```powershell
cd backend
uv run ruff check .
uv run ruff format --check .
uv run mypy app
uv run pytest
```

## Frontend

```powershell
cd frontend
flutter pub get
flutter emulators --launch <emulator-id>  # or connect a device
flutter run
```

The scripted UI preview (P1 fake repositories) is opt-in; a plain build shows no fake data:

```powershell
flutter run --dart-define=CINEME_PREVIEW=true
# or: flutter build apk --debug --dart-define=CINEME_PREVIEW=true; flutter install -d <device-id> --debug
```

Preview mode is not labelled on screen; it is identified by this build flag. Optional local posters for the preview go in `frontend/preview_posters/<tmdbId>.jpg` (git-ignored, see that folder's README and ADR 002); without them the designed placeholder is shown.

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

If `flutter pub get` or Gradle fails with "not enough space on the disk", redirect caches for the current PowerShell session:

```powershell
$c = 'D:\cineme-tool-cache'
$env:TEMP = "$c\tmp"; $env:TMP = "$c\tmp"; $env:PUB_CACHE = "$c\pub"; $env:GRADLE_USER_HOME = "$c\gradle"
```
