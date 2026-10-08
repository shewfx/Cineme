# Shows and anime: design and implementation plan

Status: **implemented on branch `feat/series-next-episode`** (2026-10-08, based on `main` at the merge of PR #15); see "Implementation notes" at the end for what shipped and how it differs from this plan. Not merged, no hosted migration, no deployment or release yet. Decision record: [ADR 011](adr/011-shows-and-anime-next-episode.md). This document replaces the sketch in `ROADMAP.md` §6. The series release version is assigned when implementation scope is approved; no version is bumped for planning.

## 1. What exists today (inspected)

| Area | Fact (file) | Consequence |
|---|---|---|
| Movie identity | `movies.tmdb_id` bigint PK; `watchlist_entries`, `viewings`, `movie_blocks`, `recommendations.movie_id` reference it (`backend/app/*/models.py`) | TV and movie TMDB ids overlap, so series need their own tables and an explicit media type |
| Watchlist API | `POST /watchlist {tmdb_id}`, `GET /watchlist` returns `items[{id,movie,added_at,source_type}]` with server-side sort and keyset cursors | Needs a media filter and a union query; request default must stay "movie" |
| Recommendations | one row per attempt, `movie_id` nullable already (no_match), partial unique index "one offered/accepted per session", `winner_snapshot` JSONB, check "selected rows have movie and score" | An episode pick fits the same row with one more identity shape; the check must be relaxed, not the index |
| Engine | pure `rank(RankingInput, EngineConfig)`, `weighted_v1`, score `35G+30C+10D+10A+10R+5Q`, config keys are exact and weights must sum to 100 (`engine.py`, `weights_v1.json`) | A new component or key needs a new engine and config version |
| Continuity | **absent.** `grep` finds no series/continue logic. R (recommendation recency) and D (diversity versus the last three viewings) would both *penalize* continuing a series if applied naively | Continuity is new, and R/D need explicit episode rules (§6) |
| Skip semantics | "Not tonight" excludes the item for the session (`offered_this_session`) and lowers R the next days; never a dislike; third rejection pauses | Reused unchanged for episodes |
| Block | `movie_blocks`, reversible, hard filter, does not touch the watchlist | A parallel `series_blocks` |
| Watched | one canonical viewing writer; Mark watched completes the day; follow-up `yes/no/not_yet` for earlier accepted picks; idempotency ledger + users-row lock first (`DATA_MODEL` "Atomicity") | Episodes follow the same lock order and ledger |
| Ratings | movie `viewings.rating` 1–5 feeds the genre evidence G only | Episode and series ratings are stored separately and feed nothing (§7) |
| Preferences | `user_preferences` versioned row, `PATCH /me/preferences` with `expected_version`, recommendation-affecting edits supersede the open pick without choosing a replacement | `tonight_media` is a recommendation-affecting preference |
| "Tonight settings" | `ContextView` (first Tonight screen) and `EditTonightPage` (`/today/context`) hold the three selectors (`SelectorField` + option sheet) | The media control goes there |
| Provider | `TmdbProvider` (httpx, retries, 429 mapping, 24 h genre cache, trending/popular caches), `MovieMetadataProvider` Protocol, metadata cache in `movies` | Add TV methods to the same provider and error mapping |
| Limits | 500 active watchlist entries; 30 s function budget; no background jobs (non-goal) | Episode data is fetched at add time and refreshed on read, outside locks |
| Migration head | `0007` on `main`; hosted DB at `0006` before PR #15 | Revision numbers are chosen at implementation time from the then-current head; none is reserved here |

## 2. Product behavior

Tonight offers one movie **or** one episode. The user flow is unchanged: context, then one card, then Watch Tonight / Mark watched / Not tonight / Pick another / Never recommend.

**Next eligible episode.** Regular episodes are ordered by (season ≥ 1, episode) from TMDB. With progress pointer `P` (the last watched episode, or none) the series' *next episode* is the first regular episode strictly after `P` (or the first regular episode if `P` is none). Only that one episode is ever considered for the series. Eligibility of that episode:

| Condition | Result |
|---|---|
| air date known and ≤ the caller's local date | aired: eligible for ranking |
| air date unknown or in the future | not eligible (`next_episode_not_aired`); later episodes are *not* considered, so nothing is skipped |
| no later regular episode, series status Returning/In Production/Planned | not eligible (`series_caught_up`) |
| no later regular episode, status Ended/Canceled | not eligible (`series_completed`) |
| no episode data cached and TMDB cannot supply it | not eligible (`series_unavailable`), reported, never silently dropped |
| runtime known | compared with the effective runtime cap like a movie |
| runtime unknown | `runtime_unknown`: excluded when a cap exists, eligible with no cap, shown as "Runtime unknown" (never estimated; open decision D1) |
| series blocked, genre blocked/avoided tonight, offered this session | same exclusions as movies |

Specials (season 0), multi-part episodes and alternate orders are out. The UI says: "Specials aren't included yet. Cinemé follows TMDB's standard season and episode order; some shows, especially anime, may be ordered differently where you watch."

**Progress.** "Last watched: Season 1, Episode 4" is stored per user and series. Setting it (series details, or "Set my progress" from an episode card) accepts any aired regular episode known to the cache, or "Not started". Setting it never creates viewings for skipped episodes and never counts toward continuity. It supersedes an open or accepted pick for that series without choosing a replacement. **Mark watched** records one viewing of the next episode and advances the pointer to it in the same transaction; it is the only way watching moves progress forward. Marking an episode that is not the next one is rejected (`NOT_NEXT_EPISODE`), never accepted as a silent skip; to jump ahead the user sets progress explicitly. **Watch Tonight** only marks the recommendation accepted.

**States for a series on the watchlist** (shown on its row/details): Up next (S1 E5), Next episode airs <date>, Caught up, Finished, Unavailable.

**Mark watched completes the day** (like movies); a second episode the same night is out of scope (D2).

### Tonight media preference

`tonight_media`: **Movies only** (default for everyone, including existing users), **Movies & shows**, **Shows only**. Server-side in `user_preferences`, versioned, therefore identical on every device. Shown as a "What to watch" selector (option sheet with the current choice and a chevron, like the other three) on the first Tonight screen and on Edit tonight, with the note "Saved for every night". Behavior:

- Movies only: movie candidates only. Shows only: next-episode candidates only (anime included). Movies & shows: both in **one pool, one ranking, one result** (no quota; the deterministic score decides).
- Changing it supersedes an open pick exactly like other recommendation-affecting preferences (the existing "Replace tonight's plan?" confirmation applies to an accepted plan) and changes nothing else: no viewing, watchlist row or progress is touched.
- Shows only and nothing eligible: never a movie. With no series on the watchlist the state is `empty_watchlist` with `empty_reason: "no_shows"`: "No shows in your watchlist yet." Actions **Add shows** and **Change preference**. With series but none eligible it is the normal `no_match` with counts (caught up, finished, not aired yet, unavailable, runtime) and the same two actions. Movies & shows with candidates of only one kind just ranks that kind and says nothing special.
- Movies hidden by the preference are reported as `hidden_by_preference` (an informational count, not part of the exclusive sum), so a user never wonders where their films went.

### Watchlist media filter

A separate dropdown (the app's option sheet, Browse/Sort style): **All** (default), **Movies**, **Shows** (anime included). It filters the displayed list only and is independent of `tonight_media`. The selection is device-local like the sort and layout choices, held in a provider so it survives opening details and coming back. It sends `media=all|movies|shows` so keyset paging stays server-side. Empty category: "No shows in your watchlist yet." with **Add shows**, or "No movies…" with **Add movies**. Filtering never deletes or edits anything.

### Search and add keep media explicit

The add screen keeps the search field on top and gains a **Movies | Shows** control under it (default Movies). Movies behave exactly as today (discovery dropdown included). Shows searches `GET /tv/search`; rows are labelled "Show"; the add request names the media type. Results never mix silently. Discovery lists for shows are out of the first release. Series details live at `/series/:tmdbId` (movies stay `/movies/:tmdbId`); the entry id is a UUID in a different table, so no id can mean two things.

## 3. Data model (proposed; revision numbers are chosen at implementation time)

All tables in schema `cineme`; additive; existing tables keep their meaning.

- `series`: `tmdb_id bigint PK`, `name`, `original_name`, `first_air_date`, `last_air_date`, `status` (TMDB), `genre_ids int[]`, `poster_path`, `overview`, `vote_average`, `vote_count`, `original_language`, `origin_countries text[]`, `adult`, `metadata_status`, `fetched_at`, `episodes_fetched_at`. Shared cache, no user data; validated like `movies` (relative poster path, ranges).
- `series_episodes`: `(series_id, season_number ≥ 1, episode_number ≥ 1)` PK, `tmdb_episode_id`, `name`, `air_date`, `runtime_minutes` (null = unknown, check 1..600), `fetched_at`. Specials are not stored.
- `series_entries` (per user): `id uuid PK`, `user_id`, `series_id`, `status active|removed`, `added_at`, `removed_at`, `progress_season`, `progress_episode` (both null or both set), `progress_version int`, `progress_updated_at`, `series_rating smallint null`. UNIQUE `(user_id, series_id)`. Removal archives the row and **keeps progress**; re-adding restores it (age resets, progress stays).
- `episode_viewings`: `id`, `user_id`, `series_id`, `season_number`, `episode_number`, `watched_at null`, `recorded_at`, `source` (`recommendation`, `manual`, `follow_up`), `recommendation_id null`, `rating smallint null` (1–5, episode rating), `version`, `episode_name_snapshot`. UNIQUE `(user_id, series_id, season_number, episode_number)`: one watch per episode, which is what makes retries and two devices idempotent. Movie `viewings` is untouched.
- `series_blocks`: `(user_id, series_id)` PK, `created_at`; reversible; leaves the entry and progress alone.
- `user_preferences.tonight_media text NOT NULL DEFAULT 'movies'` with a CHECK on the three values; the existing default makes every current row Movies only.
- `recommendations`: add `media_kind text NOT NULL DEFAULT 'movie'`, `series_id`, `season_number`, `episode_number`; replace the "selected rows have a movie" check with "selected rows have exactly one identity: `movie_id`, or `series_id`+season+episode"; relax `total_score` from ≤ 100 to ≤ 100 + the config's maximum continuity bonus. The partial unique index and the rest stay. Old code only writes movie rows, which satisfy the new check, so a deployed old backend keeps working after the migration.
- Winner snapshots for episodes carry series display data, season, episode, episode name, air date, runtime and the continuity inputs.

Lock order stays: `users` row, then the owned session, then the series entry. No network call inside a lock.

## 4. Metadata and the TMDB provider

All TMDB calls stay in the backend, through the existing `TmdbProvider` (timeouts, one retry, 429/5xx mapping, no secrets in logs). New provider methods: `search_tv`, `tv_details`, `tv_seasons` (episode lists; seasons fetched with `append_to_response=season/N` in chunks of at most 20, which stays inside the 30 s function budget), plus TV watch providers later. Normalization mirrors movies (unknown stays null; runtime 0 becomes null; invalid dates null; unvetted paths dropped).

Freshness without background jobs: the series and its regular episodes are fetched when the series is added. A returning series is refreshed on read when its cache is older than 24 h, an ended one after 7 days; stale data is served if a refresh fails. `POST /today/choose` refreshes at most three stale entries first, outside any lock and within the budget, and otherwise uses the cache. A series with no episode data at all is `series_unavailable`.

## 5. API (proposed contract; additive, capability-gated)

**Capability header.** A client that supports series sends `X-Cineme-Features: series-v1` on every request. Without it the server behaves exactly as today: watchlist, blocks, search and Today contain movies only, the stored preference is ignored for that client, and nothing it receives has a new required field. New clients feature-detect an old backend by the absence of `preferences.tonight_media` in `GET /me` and hide all series UI.

| Endpoint | Behavior |
|---|---|
| `GET /tv/search?q=&page=` | like movie search: `SeriesSummary{tmdb_id,name,year,genres,poster_url,status,can_add}`, bounded pages |
| `GET /tv/{tmdb_id}` | `SeriesDetails` + `stale` + `limitations` text + (if on the caller's watchlist) `entry{id,status,progress{season,episode,version},next{state,episode?},series_rating}` |
| `GET /tv/{tmdb_id}/seasons` | seasons with episode lists (regular only) for the progress picker |
| `POST /watchlist` | body `{"media_type":"series","tmdb_id":1399}`; absent `media_type` means `movie` (old requests are unchanged); `201/200 already_present`; `409 SERIES_BLOCKED`, `409 WATCHLIST_LIMIT` (500 combined), `422 SERIES_INELIGIBLE` |
| `GET /watchlist?media=all\|movies\|shows&sort=&cursor=` | items gain `media_type`; series items carry `series{...,next_state}` instead of `movie`; one keyset order over both tables; default `all` for capable clients, `movies` otherwise |
| `DELETE /watchlist/{entry_id}` | archives either kind (the id resolves to exactly one table) |
| `PUT /series/{tmdb_id}/progress` | `{expected_version, last_watched:{season,episode}\|null}` + Idempotency-Key; `409 VERSION_CONFLICT` with current progress; `422 EPISODE_NOT_FOUND` / `EPISODE_NOT_AIRED`; supersedes an open pick for the series; creates no viewings |
| `POST /series/{tmdb_id}/episodes/watched` | `{season,episode,rating?}` for the *next* episode only, atomic with the pointer; replay-safe; `409 NOT_NEXT_EPISODE` with the actual next episode |
| `PATCH /episode-viewings/{id}` | `{expected_version, rating}` episode rating |
| `PATCH /series/{tmdb_id}/rating` | optional series rating (D6) |
| `POST/DELETE /me/blocks/series/{tmdb_id}`, `GET /me/blocks` | series blocks; the list includes series only for capable clients |
| `PATCH /me/preferences` | `tonight_media` with `expected_version`; response unchanged in shape (`preferences` + `today`) |
| `GET /today`, `POST /today/choose`, accept/reject/watched/follow-up | `recommendation.media_kind` (`movie` default) and, for episodes, `episode{series,season,episode,name,air_date,runtime_minutes,continues_series}`; `POST /recommendations/{id}/watched` takes the optional episode `rating`; follow-up works on episode picks |
| Today states | no new state names. `empty_watchlist` gains `empty_reason` (`no_movies`, `no_shows`, `none`); `no_match.counts` gains `series_caught_up`, `series_completed`, `next_episode_not_aired`, `series_unavailable`, `series_blocked`, and `hidden_by_preference` (informational) |

Every mutation keeps the documented rules: ownership from the token, idempotency key, `expected_*` versions, errors in the standard envelope. The Today session version increments once per committed command.

**Idempotency and devices.** Mark watched inserts the episode viewing `ON CONFLICT DO NOTHING` and moves the pointer only forward (`progress < episode`), so a replay, a double tap or a second device returns the same viewing and never advances twice. If the pointer already moved past the episode (another device, or a manual correction), the recommendation is stale: `409 INVALID_TRANSITION` and Today reloads. Progress corrections are guarded by `progress_version`. A correction that races a Mark watched resolves by the users-row lock: whichever commits second sees the other's result.

**Remove / block / re-add.** Removing keeps progress and history. Blocking removes the series from candidates and from Add (`SERIES_BLOCKED`) without touching progress. Unblocking and re-adding restore everything. Removing or blocking the currently recommended series supersedes the pick without a replacement, as for movies.

## 6. Recommendation engine: `weighted_v2` and series continuity

`weighted_v2` with config `weights_v2`: the six weights and all existing parameters are copied unchanged (still summing to 100) and a `continuity` block is added. `weighted_v1` and its stored recommendations stay valid and replayable. A test asserts that, for movie-only input, `weighted_v2` returns the same components, totals, order and reasons as `weighted_v1`.

**Candidates.** Active movie entries, and active series entries each reduced to their single next-episode candidate (or an exclusion code if there is none). The media preference removes candidates of the other kind first; their number is reported as `hidden_by_preference`. Exclusion precedence for series candidates: `series_unavailable`, `series_completed`, `series_caught_up`, `next_episode_not_aired`, `series_blocked`, `offered_this_session`, `genre_blocked`, `runtime_unknown`, `runtime_exceeded`; primary counts still sum to the number of candidates. Eligibility is therefore always applied before ranking: aired status, runtime, media preference, blocks, skips.

**Base score of an episode** uses the six existing components with these inputs: G, C, Q from the series' genres and votes (G still learns only from movie ratings: nothing about episodes or series ratings enters it); A from the series' watchlist age; R from the *episode's* own last offer (a never-offered next episode is R = 1, so continuing a series is not penalized for last night's different episode); D from the last three known viewings **excluding the candidate's own series** (otherwise last night's episode would zero D for its successor).

**Continuity bonus** `S`, added to episode candidates only (movies: 0), in score points:

```
L        = caller's local date
confirmed watches of the series = episode_viewings with local date of COALESCE(watched_at, recorded_at)
           in [L - 21 days, L]; only Mark watched and follow-up "yes" create them (never accept,
           never display, never a progress correction)
n        = their count            last = local date of the newest one       days = L - last
if n = 0:  S = 0
fade     = max(0, 1 - days / 21)                      # 0 after 21 idle days
momentum = 0.5 + 0.5 * min(1, (n - 1) / 2)            # 1 watch 0.5, 2 watches 0.75, 3 or more 1.0
S        = 12 * fade * momentum * R_episode           # R_episode in [0,1]: 1 never offered, 1/14 offered yesterday
episode score = 35G + 30C + 10D + 10A + 10R + 5Q + S
```

Constants (12 points, 21 days, 3 watches) live in `weights_v2.json`, are validated (`0 ≤ S_max ≤ 20`, window ≥ 1), hashed with the config and stored per recommendation. Decimal arithmetic, precision 28, HALF_EVEN, same as v1. Tie break: total (unrounded) descending, then `added_at` ascending, then movie before series, then TMDB id ascending. The score is a deterministic sum of points, not a probability, and nothing here is random.

Properties:

- **Confirmed watching raises priority; displaying or accepting does not**: only `episode_viewings` count, and they are created only by the two confirming actions.
- **Beats an equally suitable series**: with equal base scores the series with S > 0 wins; a watch yesterday with three or more recent watches gives S = 12 × 20/21 = 11.43.
- **Cannot lock in**: S ≤ 12 whatever n is (momentum saturates at three watches), it falls linearly to 0 after 21 idle days, and a candidate that is *materially* better still wins: any rival with a base score more than S points higher wins (for example a confirmed intent match, worth 18 points through C, beats a full bonus; a mere watchlist-age or recency difference, at most 10, does not).
- **Temporary skip lowers it through existing semantics**: "Not tonight" excludes that series for the day (`offered_this_session`) and tomorrow `R_episode` is 1/14, which shrinks both R and S (12 → 0.86), recovering over 14 days. No new penalty state exists; it is not a dislike.
- **Never recommend** adds a series block, a hard exclusion before ranking.
- **Caught up / finished / unavailable** series have no episode candidate and cannot win; another title is considered.
- **Mood and ratings**: `current_mood` stays metadata only. Desired experience acts through C on the series' genres exactly as for movies. Ratings (movie, episode, series) do not enter S; only movie ratings feed G.
- **Movies are never boosted or penalized** by S; a movie that is materially better wins.

Worked example (synthetic, to become a test fixture): series A (watched 3 of the last 5 days, last yesterday, next episode never offered) base 58.0 + S 11.43 = 69.43; series B same genres, no recent watches, base 58.0 → 58.0; a film with base 66.0 → 66.0. A wins. If a "Not tonight" on A's episode yesterday: R_episode = 1/14, A's base drops by 10 × (1 − 1/14) = 9.29 and S becomes 0.82 → 49.5, so the film wins. If the user watched nothing for 22 days: S = 0, A ties B and the tie-breaks decide.

**Reasons.** New reason `continues_series` (source: continuity inputs), emitted when S > 0 and S is the strongest positive contribution, which it is whenever it applies unless a larger one exists; text: "Continue the series you're watching — S1 E5." Other episode reasons: runtime fit ("45 minutes, within your 60-minute limit."), genre and context reasons as for movies, and "Season 2, Episode 3 is next." Specials and order caveats are not repeated on the card. The Why drawer lists all components plus "Series continuity +11.43 (3 episodes in the last 21 days)" and the engine/config versions.

**Existing rejection reasons on an episode.** Not tonight / Different genre / Too long / Something lighter work unchanged (scoped, temporary). "Already watched" is replaced for episodes by **Set my progress**, because it must never move progress silently. Never recommend blocks the series.

## 7. Ratings and evidence

Episode rating: optional 1–5 on `episode_viewings`, offered on Mark watched, editable by version. Series rating: optional 1–5 on `series_entries` (D6). Both are stored and shown, and neither feeds G or any score in this release; the movie evidence formula, its tests and `weights_v1` are untouched. Using them later needs its own ADR, engine version and fixtures.

## 8. Frontend design

New models `Series`, `Episode`, `WatchlistItem` (sealed: movie or series entry) alongside the unchanged `Movie`; repositories behind the existing interfaces (preview fakes included, never touching the network). Tonight: an episode card reusing the hero (series poster, "S1 E5 · Episode name", runtime, air date) and the same actions; a "What to watch" selector in `ContextView`/Edit tonight; Shows-only empty/no-match states with Add shows and Change preference. Watchlist: media dropdown, series rows with up-next state, `/series/:tmdbId` details with progress ("Last watched: S1 E4", Set progress picker, Mark next episode watched, remove, never recommend, rating), the limitation note. Search/add: the Movies | Shows control. History: episode viewings in a separate segment (D13). The client sends the capability header and hides series UI when `tonight_media` is absent from `GET /me`.

## 9. Rollout and compatibility

1. Migrations are additive and applied to the hosted database first, after a dry run (`migrate_hosted.py`), because deployed code that does not know them keeps working.
2. Backend next: header-gated, so existing web bundles and installed APKs see no change.
3. Web, then APK, with a version assigned at that point.
4. Rollback of code is safe at any step; migrations are forward-only (a corrective migration if one is wrong).

Older client + new backend: movies only, as today (D3 records the stricter alternative). New client + older backend: series UI hidden. The PWA's cached old bundle is an "old client" until it reloads. A pick made on a new client while an old client is open: the old client sees no current pick (it does not render episodes), and if it chooses, the server picks a movie and supersedes the episode.

## 10. Ordered implementation plan

Each stage is a separate approved task: its own branch and PR, focused checks, no hosted migration or deployment inside it.

| Stage | Scope | Focused validation |
|---|---|---|
| S0 | Review and accept ADR 011 and this design; assign the release version | review only |
| S1 | Series foundations, no recommendations: migration for `series`, `series_episodes`, `series_entries`, `episode_viewings`, `series_blocks`; provider TV methods and normalization; `GET /tv/search`, `/tv/{id}`, `/tv/{id}/seasons`; cache and freshness | recorded TMDB fixtures through the mock transport (partial, malformed, runtime 0, long shows, specials dropped), error mapping, cache/stale behavior, constraints and migration up/down on PostgreSQL |
| S2 | Watchlist union and the media filter: `POST/DELETE /watchlist` with `media_type`, `GET /watchlist?media=`, capability header, series blocks; Flutter models, the Movies \| Shows add control, Watchlist dropdown, series rows and details (no progress yet) | ownership/isolation across both kinds, keyset paging over the union in every sort, 500 combined cap, header-less clients unchanged (existing tests untouched), Flutter widget tests incl. filter persistence through details |
| S3 | Progress and episode history: progress PUT, next-episode computation, Mark next watched, episode ratings, remove/re-add/block semantics, series details progress UI | pure next-episode function with injected dates (gaps, specials, unaired, ended/returning, renumbering), concurrency (double tap, two devices, correction vs mark), idempotent replay, progress preserved across remove/re-add/block |
| S4 | Engine and Today: `tonight_media` migration and PATCH, `weighted_v2`/`weights_v2`, episode candidates and exclusions, continuity, `recommendations` constraint change, accept/reject/watched/follow-up for episodes, no-match and empty states, reasons, comparison storage | full fixtures including the §6 example, v1/v2 movie-only equivalence, continuity boundaries (0, 1, 21, 22 days; n = 1, 2, 3, 10), skip interaction, shuffled input, bounded evidence size, preference changes leave history/progress untouched, capability-gating matrix |
| S5 | Tonight UI: episode card, media preference control, empty and no-match states, Set my progress from the card, episode Why drawer | widget tests for each state at 360×640 and 200 % text, account switch, stale-version reload |
| S6 | History segment for episodes, accessibility pass, documentation, hosted rollout runbook, release version and changelog | full gates (`ruff`, `mypy`, `pytest` on PostgreSQL; `dart format`, `flutter analyze`, `flutter test`; web build and bundle scan), dry run of the hosted migration |

Out of scope throughout: specials, alternate or absolute orders and external anime sources, multi-episode bundles, push notifications, background jobs, discovery lists for shows, using ratings in scoring, playback.

## 11. Open decisions (recommended default)

| # | Decision | Default |
|---|---|---|
| D1 | Unknown episode runtime | stays unknown: excluded under a runtime cap, eligible without one; no series-level estimate |
| D2 | Does Mark watched on an episode complete the day (one thing per night)? | yes, like a movie |
| D3 | Older client while `tonight_media` is not Movies only | movies only for that client (documented exception); alternative: a blocking "update the app" error |
| D4 | Continuity constants | 12 points, 21 days, 3 watches, to be tuned with fixtures before S4 closes |
| D5 | Reject reason "Already watched" on an episode | replaced by "Set my progress" |
| D6 | Series rating in the first release | store and show on details; do not feed scoring; may be deferred to S6 |
| D7 | Watchlist media filter persistence | device-local, like sort and layout |
| D8 | Search | separate `GET /tv/search` behind a Movies \| Shows control, not a mixed list |
| D9 | Anime badge | none in the first release; anime is just a series |
| D10 | Episode title on the card | shown (the next episode is already implied by progress) |
| D11 | Watchlist cap | 500 combined movies and shows |
| D12 | Refresh budget at pick time | at most three stale series per `choose` |
| D13 | Episode history | separate segment in History, not mixed into movie history |
| D14 | Mixed pool balance | none; one score decides |
| D15 | A series entry added while Tonight already has an accepted pick | preserved, like adding a movie |

## 12. Implementation notes (stages S1 to S6, one branch)

All six stages were built together on `feat/series-next-episode`, with the documented defaults for D1 to D15 unless noted. Migration `0008` (after head `0007`) adds the tables of section 3. Contracts: `API_CONTRACT.md` "Shows and anime", `DATA_MODEL.md`, `RECOMMENDATION_ENGINE.md` "`weighted_v2`", `FRONTEND_SPEC.md`.

Differences and additions relative to the plan above:

- **Diversity (D) rule made precise.** Among the last three known viewings (films and episodes), those of the candidate's own series are dropped, not replaced by an older one. A freshly watched show therefore reads D = 0.5 instead of 0. The 5-point gap this leaves between a just-watched show and an identically-genred rival comes from the existing variety signal and fades only as newer viewings displace it; it is separate from the continuity bonus, which does fade after 21 idle days.
- **D12 (refresh at pick time) is implemented** as `refresh_stale`: before `POST /today/choose` and a replacement pick, at most three stale shows (never-loaded first, then oldest) are refreshed outside any lock within a 12 second budget; failures fall back to the cache. This is how a returning show stops being "caught up". Adding, opening a show, loading seasons and setting progress also refresh through the same freshness rule (a day for returning shows, a week for ended ones).
- **Blocks list** is a separate `GET /me/blocks/series` (no cursor), and Profile gets a "Blocked shows" list with Unblock.
- **History** gets the Episodes segment backed by `GET /episode-viewings`; `GET /recommendations` hides episode picks from clients without the capability header.
- **The union watchlist** is one SQL `UNION ALL` ordered by the same eight sorts and keyset cursors as films; a show has no single runtime, so it sorts with the unknown runtimes in both directions.
- **TV genre ids** differ from film ids, so two intent maps in `weights_v2` also list 10759 (exciting) and 10765 (deep), and display names merge the TV registry (film names win). This is the same genre heuristic as for films, not a new signal.
- **Not built:** a series rating control (the endpoint exists and stores a separate 1 to 5 value), editing an episode rating after Mark watched (the endpoint exists), anime-specific badges, discovery lists for shows, and any use of episode or series ratings in scoring.
- **Frontend identity.** `Movie` and `Series` share a small `TitleInfo` interface so posters and rows draw both, while navigation, requests and storage always carry the `MediaType`. An episode recommendation draws the show through a display-only `Movie` whose id is never used for a film lookup (availability for an episode is the show's, fetched by the TV id).

### Follow-up in PR #16: shared details frame, trending shows, show availability, Reason dropdown

- **Movie vs Show Details audit.** Shared (one component each): blurred poster backdrop and gradients (`DetailsBackdropScaffold`), header with poster, title and facts, overview, Where to watch (`AvailabilitySection`, detailed states, provider priority Netflix, Prime Video, JioHotstar, Apple TV, at most 3 chips plus "+N more", streaming/rent/buy, JustWatch attribution), stale note, scroll hint, pinned Remove and Never recommend. Intentional differences: a show has progress with Mark episode watched and Set my progress instead of a film Mark watched / rating / history; its facts have no runtime; Never recommend blocks the series (undo in Profile); removing keeps progress; the availability note says it is for the show as a whole.
- **Trending shows**: `GET /tv/trending`, 12 items, hourly provider cache, shared grid widgets with the film grid; the film dropdown and onboarding are unchanged.
- **Show availability**: `GET /tv/{id}/availability`, migration 0009 adds the show's own provider cache; movie and TV ids never share a cache or a client provider key (`AvailabilityKey` carries the media type).
- **Reason dropdown** replaces the six reason chips in the "Not this one?" sheet; the options, the Already watched handling (not offered for episodes) and the request shapes are unchanged.

Validation: see `docs/IMPLEMENTATION_STATUS.md`.
