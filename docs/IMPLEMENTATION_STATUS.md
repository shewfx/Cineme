# Implementation status

Records only verified work. Phases follow [DEVELOPMENT_PLAN.md](../DEVELOPMENT_PLAN.md).

| Phase | Status |
|---|---|
| P0 — Bootable repository skeleton | Complete: local gates, manual launch/health and GitHub Actions CI verified; request-ID header tracked as outstanding |
| P1–P8 | Not started |

## P0 — 2026-10-02, branch `feat/p0-setup`

### Verified

| Check | Result |
|---|---|
| `uv run ruff check .` | All checks passed |
| `uv run ruff format --check .` | 7 files already formatted |
| `uv run mypy app` (strict) | No issues in 4 source files |
| `uv run pytest` | 6 passed (health, production docs hidden, settings defaults/env/invalid) |
| `dart format --output=none --set-exit-if-changed lib test` | 0 changed, exit 0 |
| `flutter analyze` | No issues found |
| `flutter test` | 1 passed (launch on Today placeholder) |
| `docker compose --env-file infra/.env -f infra/compose.yaml config --quiet` | Exit 0; clear error when `POSTGRES_PASSWORD` is unset |
| PostgreSQL `up -d` + `ps` | Container reported `(healthy)` (confirmed by the user) |
| `git check-ignore -v infra/.env` | Ignored by `.gitignore:2:.env` |
| Manual: `uvicorn` + `Invoke-RestMethod /healthz` | `{"status":"ok"}` |
| Manual: `ENVIRONMENT=bogus` | Startup fails with a validation error naming `environment` |
| `flutter build apk --debug` | Exit 0; `app-debug.apk` produced |
| Android launch | `flutter install -d emulator-5554` (Android 17, API 37 emulator) with the D: cache workaround; `dev.cineme.cineme/.MainActivity` was the top resumed activity; screenshot showed the dark "Cinemé / One movie. No scrolling. / Tonight's pick is not available in this build yet." placeholder |

### Outstanding

- **CI workflow:** verified. [Run 36962545446](https://github.com/shewfx/Cineme/actions/runs/36962545446) on `feat/p0-setup` (commit 29981c2): backend, frontend, compose all succeeded. Runner notices to address later: actions/checkout@v4 and setup-uv@v6 target deprecated Node 20; `ubuntu-latest` moves to Ubuntu 26 from 2026-10-19.
- **Request-ID header:** API_CONTRACT requires every response to carry a request ID header. Not implemented at P0; must land with the error envelope before any contract-facing endpoint is considered done.

### Known notes

- `uv run pytest` reports 1 warning, emitted by **starlette 1.7.0** (`starlette.testclient`, imported via `fastapi/testclient.py:1`, fastapi 0.142.2) when it detects httpx 0.28.1:
  ``StarletteDeprecationWarning: Using `httpx` with `starlette.testclient` is deprecated; install `httpx2` instead.``
  Tests still pass. HTTPX stays (ARCHITECTURE A02); the warning alone is not a reason to switch. Revisit at P3 or when a Starlette release drops httpx support.
- Dio and the Riverpod `AppConfig` are deferred until the first HTTP call ([ADR 001](adr/001-baseline.md)).
- The C: drive was full during setup; pub/Gradle caches were redirected to `D:\cineme-tool-cache` ([TOOLING.md](TOOLING.md#low-disk-space-on-c)). The Android SDK on this machine is at `F:\astudio` (adb is not on PATH).
