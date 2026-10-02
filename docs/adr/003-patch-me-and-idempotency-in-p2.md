# ADR 003 — PATCH /me and the idempotency ledger in P2

Status: accepted by the project owner, 2026-10-02.

## Decision

P2 implements the documented `PATCH /api/v1/me` (display name and IANA timezone) together with the `idempotency_records` table and a small ledger, both previously scheduled for P3. Preference editing (`PATCH /me/preferences`) stays in P3/P4, because its contract response includes a Today envelope that does not exist before P4.

## Why

P2 needs one real private mutation to prove the documented write rules end to end on PostgreSQL: identity from the verified JWT only, the users-row lock, a UUID `Idempotency-Key`, replay of an identical committed request, `IDEMPOTENCY_CONFLICT` for a reused key with a different request, and no cached result for a failed transaction. `PATCH /me` has a self-contained response (the profile), so it fits without inventing Today.

## Tradeoff

One extra table arrives a phase early. The ledger stays deliberately small (one module; lookup and store inside the mutation's transaction after the user lock; 24-hour replay window; no background cleanup job, expired rows are replaced on reuse). Bootstrap remains exempt as documented.

## Affected contracts

- DATA_MODEL "Additive migration schedule": P2 adds `idempotency_records` (columns as specified, unique `(user_id, key)`, expiry index).
- API_CONTRACT: no shape change. `PATCH /me` and its error codes are implemented as written; `IDEMPOTENCY_KEY_REQUIRED` is the 400 code for a missing or non-UUID key.

## Validation

PostgreSQL integration tests: replay without re-applying, conflict on a different body, per-user key scope, failed request not cached and retryable with the same key, five concurrent retries applying once, missing/invalid key 400, validation 422, no profile 409.
