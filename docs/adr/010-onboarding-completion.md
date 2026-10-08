# ADR 010 — Server-owned onboarding completion

Status: accepted by the project owner, 2026-10-08. Release v1.1.0.

## Decision

Whether a new account has finished first-run onboarding is stored on the server as `users.onboarding_completed_at timestamptz NULL` (migration `0007`). `NULL` means onboarding is still needed. `GET /me` returns it as `onboarding_completed_at`. `PATCH /me` accepts `onboarding_completed: true`, and only `true`: the transition is one way (`false`, `null` and other values are 422), and a repeat never moves the original timestamp. Skip and Continue both send it; leaving the screen any other way (closing the app, signing out, Android back) does not.

Migration `0007` backfills every existing user with their `created_at`, so no existing account is ever sent through onboarding. There is no stored step or counter: progress is the watchlist itself, which already survives retries and interruptions because each add is saved immediately through `POST /watchlist`.

Clients treat a `GET /me` response without the field (an older backend) as complete.

## Why

Client-side flags would repeat onboarding on every new device and could not distinguish an existing user from a new one. A server timestamp resumes across sessions and devices, and the backfill is a one-line, auditable guarantee for current users. Reusing `PATCH /me` keeps one idempotent, user-locked profile mutation (ADR 003) instead of adding an endpoint for one boolean.

## Tradeoff

One nullable column and one additive field. Skipping and finishing are indistinguishable by design; if the product ever needs to tell them apart, that needs a new column. Accounts created between the migration and the backend deploy by an older backend start with `NULL` and see onboarding once on a new client, which is the intended behavior for new accounts.

## Affected contracts

- DATA_MODEL `users`: `onboarding_completed_at`.
- API_CONTRACT: `MeResponse.onboarding_completed_at` (nullable, additive); `PATCH /me` request field `onboarding_completed` (`true` only).
- FRONTEND_SPEC: the onboarding screen and gate.
- No change to recommendation, watchlist or Today behavior. Onboarding never creates a pick; Continue or Skip with an empty watchlist ends in Tonight's existing empty-watchlist state.

## Validation

PostgreSQL: migration up/down/up with the backfill asserted; completion is monotonic and idempotent (same key replays, new key keeps the timestamp); `false`/`null` are rejected without changing state; two-user isolation. Flutter: gate routing, resume with existing films, duplicate/failed adds, failed completion retry, back behavior, account switch, 200 % text, absent-field compatibility.
