# ADR 008: Tonight setup with compact selectors, a Skip path, and server-side Watchlist sorting

Status: accepted by the project owner, 2026-10-03 (UI refinement request).

## Decision

1. **One selector pattern for every Tonight setup screen.** The first Tonight screen, "Ready for another pick?" and Edit tonight all show three compact full-width fields (What do you want from tonight? / How are you feeling? *optional, never decides the pick* / How much time? *optional*) that open the shared bottom-sheet option list with the current value checked. The chip wall is gone. When the feeling is *Down* and no intent is chosen yet, the intent sheet offers exactly the four documented follow-ups (Cheer me up, Something comforting, Let me feel it, Surprise me); nothing is preselected and comedy is never implied.
2. **Branded opening.** Tonight opens with "Tonight’s the night." (wordmark, one line of Jost, a thin coral rule) for about 0.9 s, once per launch, only in front of a fresh setup screen. It doubles as the loading state while Today loads. An existing pick is never held behind it.
3. **Skip, just pick something** (first Tonight screen only). It sends `POST /today/choose` with `context = {desired_experience: "surprise"}` and nothing else: the explicit **Surprise me** intent that PROJECT_SPEC already defines ("skips inference and uses the same deterministic scorer"). It is not a new backend mode, so there is no hidden default intent, no inferred trait and no randomness: hard eligibility, profile limits, the one-pick invariant, pause rules and idempotency all apply unchanged, and the result is one film from the user's own watchlist or an honest no-match. Anything half-selected in the fields is ignored by Skip. The session records Surprise me as its intent, and Today shows it as such.
4. **Watchlist sorting is server-side.** `GET /api/v1/watchlist` gains `sort` (`added_desc` default, `added_asc`, `title_asc/desc`, `year_asc/desc`, `runtime_asc/desc`). Keyset pagination is built over the sort keys, unknown year/runtime always sorts last in both directions, ties break by title then entry id, and a cursor is bound to its sort (a mismatched cursor or unknown sort is 422). Flutter keeps only the chosen sort on the device (`watchlist_sort`); list and poster layouts share it.
5. **Search/Add rows** omit an unknown runtime instead of explaining it, and use a 76x114 poster that anchors the row.
6. The shared tab header now puts the subtitle on its own full-width line under the title row, so three header actions fit at 320 px and 200% text.

## Why

The chip wall was the most cluttered screen in the app; Edit tonight already had the compact pattern, so the first screen now matches it. Skip answers "just give me a movie" without weakening any product rule, by reusing an intent the contract already allows rather than inventing a default. Sorting after loading only the pages already fetched would reorder wrongly across page boundaries on a 500-film watchlist, so the order belongs to the query.

## Tradeoff

Skip stores "Surprise me" as tonight's intent, which later explanations show. A user who only wanted to skip the questions sees that label. A saved non-default sort costs one extra list request at startup (the default order loads first, then the saved order once the local preference is read).

## Affected contracts

API_CONTRACT "Watchlist" (`sort`, cursor binding); FRONTEND_SPEC Today, Search and Watchlist sections; PROJECT_SPEC unchanged (Surprise me already defined).

## Validation

PostgreSQL integration tests for every sort, paging at limits 1/2/4 across the known/unknown boundary, search plus sort, isolation and 422s; Flutter tests for selector fields, sheets, restore/clear, intro timing, Skip (request body, failure, eligibility, one pick), search rows, and every sort, persistence, list/poster parity, pagination and narrow/200% text.
