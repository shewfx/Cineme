# Implementation status

Records only verified work. Phases follow [DEVELOPMENT_PLAN.md](../DEVELOPMENT_PLAN.md).

| Phase | Status |
|---|---|
| P0 — Bootable repository skeleton | Complete: local gates, manual launch/health and GitHub Actions CI verified; request-ID header tracked as outstanding |
| P1a — Context to one movie card (fake data) | Locally verified on branch `feat/p1a-tonight`; not committed, CI not run |
| P1b, P1c, P2–P8 | Not started |

## P1a — 2026-10-02, branch `feat/p1a-tonight`

Context-first Tonight: required desired experience (8 documented intents), separate optional mood, optional time cap, then "Pick my movie" shows exactly ONE film (designed placeholder poster, title, year, runtime, genres, 1–2 factual reasons, primary Watch Tonight). Data comes from `FakeTodayRepository` (fixed per-intent lists filtered by the hard runtime cap; mood ignored), wired only with `--dart-define=CINEME_PREVIEW=true`. Normal builds still show "not available in this build" with no fake data.

### Verified

| Check | Result |
|---|---|
| `dart format --output=none --set-exit-if-changed lib test` | 0 changed |
| `flutter analyze` | No issues found |
| `flutter test` | 10 passed: every intent × time option stays inside the cap; mood never changes the pick, Sad+Comfort ≠ Sad+Let me feel it; unknown runtime excluded under a cap; reasons factual; normal build shows no fake movie; Pick disabled until an intent (mood "Down" selects nothing); 500-film watchlist renders exactly one movie and no later-milestone actions; Watch Tonight shows intent-only note; 360×640 at 200% text with no overflow |
| Emulator (emulator-5554, preview APK) | Context screen → Keep me hooked + Tired + Up to 90 min → Pick my movie → one card: Run Lola Run, 1998 · 81 min, Action/Drama/Thriller, 2 reasons; intent and mood shown as separate tags; Watch Tonight shows the preview note and the card stays. Repeated at system font scale 2.0: both screens readable, content scrolls, Watch Tonight stays visible |

### Visual revision (same day, presentation only)

Movie screen rebuilt around full-width artwork fading into charcoal, then a compact block (context line, title, "year · runtime · genres" text line, up to two factual reasons) anchored on Watch Tonight; no page gradient, glow, badge, pills or section labels. Context screen uses the same type scale and quieter labels; the pinned "choose to continue" hint became a screen-reader hint on the disabled button. Typography: bundled Jost (OFL). Local preview posters per [ADR 002](adr/002-preview-posters.md). Repository, controller, scripted selection and reasons logic unchanged; test copy assertions updated to the new wording and one assertion added for the disabled-button hint.

| Check | Result |
|---|---|
| `dart format --output=none --set-exit-if-changed lib test` | 0 changed |
| `flutter analyze` | No issues found |
| `flutter test` | 10 passed |
| Emulator 1080×2424 (411dp) | Context → Keep me hooked + Tired + Up to 90 min → Run Lola Run with a local preview poster (synthetic generated test image, since deleted); Make me laugh → Groundhog Day with placeholder fallback; Watch Tonight note shown |
| Emulator at font scale 2.0 | Both screens readable; Past Lives card scrolls to show both reasons; button stays visible |
| Emulator 720×1280 @320dpi (360×640dp), scale 1.0 and 2.0 | Context screen scrolls with the button pinned; movie title and metadata visible above Watch Tonight at 2.0, reasons reachable by scrolling |



- Already seen, Pick another, replacement sheet, pause, accepted/completed states, Edit tonight (P1c); loading/empty/error states beyond an inline pick error, Watchlist/History/Profile (P1b).
- Down-mood follow-up shortcut (optional in spec); mood is a separate optional row instead.
- No real posters are included: the preview shows developer-supplied local files if present (ADR 002), otherwise placeholders; `poster_url` stays null until TMDB (P3/P4).
- Picking in this preview is in-memory; restarting the app returns to the context screen.



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
