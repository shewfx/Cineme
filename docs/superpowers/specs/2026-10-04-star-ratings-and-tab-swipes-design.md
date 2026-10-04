# Integer star ratings and root-tab swiping

**Status:** Design approved in conversation; awaiting review of this written spec before planning implementation.

## Intent and constraints

Replace Cinemé's four categorical viewing ratings with a nullable integer star rating from 1 through 5, and add horizontal swiping across the four main tabs. Preserve existing viewing history, optimistic version checks, idempotency, account scoping, stateful tab branches, current screen gestures, and reduced-motion behavior. Do not apply migrations to the hosted database, merge the PR, or deploy.

The current feature branch is `feat/watchlist-movie-details` and its open PR is #10. This milestone extends that branch and updates PR #10.

## Rating contract

- A rating is either `null` or an integer in `[1, 5]` end-to-end: request and response schemas, Flutter DTO/model, SQLAlchemy model, and PostgreSQL check constraint.
- Add migration `0006_star_ratings`, after `0005`, converting existing values before changing the column constraint/type: `disliked → 1`, `okay → 3`, `liked → 4`, `loved → 5`; preserve `NULL`. Downgrade maps `1 → disliked`, `2 → disliked`, `3 → okay`, `4 → liked`, `5 → loved`, and preserves null. The downgrade mapping is necessarily lossy for two-star values and must be documented in the migration.
- Migration and SQLAlchemy constraints reject values outside 1–5 while allowing null. Pydantic rejects booleans, floats, strings, zero, and values above five as ratings. Existing idempotency keys, request digests, replay bodies, version increments, and user-scoped row locks/ownership checks remain unchanged.
- Recommendation genre evidence uses `(rating - 3) / 2`: 1→−1, 2→−0.5, 3→0, 4→0.5, 5→1. This preserves all four old categorical contributions while giving two stars a midpoint; genre allocation, prior strength, deterministic arithmetic, and weights stay unchanged.

## Rating UI

- Replace `Rating` enum labels with a nullable integer model type and one reusable five-star selector used anywhere a viewing rating is entered.
- Tapping star N sets N; tapping a selected star does not clear it. Stars are whole values only. Filled stars use the existing coral accent; empty stars use muted outlines. A persistent text/semantic value below reads “N out of 5” or “No rating”; screen readers receive an accessible name and selected value for every star.
- The shared rating-edit sheet shows the movie title, selector, explicit Save rating action, and Clear rating only when an existing rating is present. It starts from the existing value. Selection is local until Save; dismissing the sheet leaves server state untouched. Clear sends null through the existing versioned, idempotent PATCH.
- The Mark watched sheet uses the same selector, stays optional/unrated by default, and retains its existing explicit Mark watched / Not yet actions. No rating is invented or selected by default.
- History viewing rows show five star positions with filled/outlined state and accessible textual value instead of categorical labels. An unrated viewing remains visibly unrated.

## Root-tab swiping

- Keep the `StatefulShellRoute.indexedStack`; swipe navigation calls its existing branch navigation so each tab retains its widget state, loaded data, nested branch location, and scroll position.
- Order is Tonight, Watchlist, History, Profile. Left selects the next index; right selects the previous; first/last boundaries do nothing. The selected navigation pill follows `shell.currentIndex`; normal tapping and re-tapping behavior remains.
- Gesture recognition belongs to the shell surface only when the active route is exactly a root tab route. Movie Details, Search, context editor, and other nested routes do not install the tab-swipe handler. Modal routes and sheets intercept gestures normally.
- Require a sufficiently long, predominantly horizontal gesture; vertical and diagonal drags do not change tabs. Use the gesture arena so child horizontal controls and Watchlist row removal can claim their own interactions before the shell. Preserve Tonight poster tilt/tap and any horizontal controls.
- Branch changes remain immediate rather than introducing a new transition, honoring reduced motion.

## Validation

- Migration tests prove all five cases including null, exact downgrade mapping, and new database constraint behavior. Do not run this migration on the hosted database.
- API/model tests cover integer round trip, nullable writes, invalid range/type rejection, same-key replay and stale-version behavior, and user ownership isolation.
- Recommendation engine tests prove the five exact evidence values and unchanged old-category equivalents, including that an edit replaces evidence rather than adding a second observation.
- Flutter tests cover star tap/label/accessibility, preselection, Save, Clear, cancellation, unrated Mark watched, and History rendering.
- Shell widget tests cover left/right direction, first/last boundaries, selected bottom-nav state, state/scroll preservation, nested-route exclusion, vertical/diagonal movement, Watchlist swipe-to-remove priority, and Tonight interactions.
- Run backend format/lint/type/unit suites plus configured PostgreSQL migration integration tests, Flutter format/analyze/full tests, and manual verification in mobile-sized Chrome and an available mobile device. Report if physical-device access is unavailable.
- Update `API_CONTRACT.md`, `DATA_MODEL.md`, `RECOMMENDATION_ENGINE.md`, `FRONTEND_SPEC.md`, and implementation status with the integer contract and legacy mapping.

## Risks and decisions

- The downgrade is lossy for two-star ratings; downgrade to Disliked as the nearest legacy bucket and state this plainly in migration comments and docs.
- A shell-level horizontal detector can conflict with row dismissal or horizontal controls; implementation must be tested with the real nested widgets and preserve child gesture priority.
- “Genuine 1–5” is interpreted as whole integer storage and interaction, not fractional stars or decimal API values.
