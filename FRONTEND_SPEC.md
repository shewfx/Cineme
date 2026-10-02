# Cinemé — Flutter frontend specification

Version 1.1. Android first, feature-first organization. Preserve the one-choice product. Polished typography and interaction matter; building a streaming catalogue does not.

## Decisions

**Decision:** Riverpod for dependency injection and async state, without generator packages; go_router for auth redirects and tabs; Dio for one central HTTP client.

**Why:** These cover server-backed screen state, test overrides and navigation with little custom infrastructure. A controller per complex feature is enough.

**Tradeoff:** Learn provider lifecycle and invalidation. Do not layer Bloc, Redux or a global mutable singleton on top. Avoid Freezed/build_runner in V1 unless an explicitly documented need emerges; plain immutable Dart models suffice.

**Decision:** Repository -> controller -> widgets, plus a small shared model set.

**Why:** Widgets can be tested with fake repositories and cannot accidentally mix UI state with API semantics.

**Tradeoff:** Some DTO mapping. Do not introduce use-case classes for every CRUD action or an abstract repository superclass.

## Folder structure

```text
frontend/lib/
  main.dart
  app.dart
  core/
    config/app_config.dart
    network/api_client.dart
    network/api_error.dart
    auth/session_store.dart
    theme/app_theme.dart
    widgets/async_state_view.dart
    widgets/movie_poster.dart
    widgets/primary_action.dart
    widgets/empty_state.dart
    widgets/error_panel.dart
  shared/models/
    movie.dart
    genre.dart
    session_context.dart
    recommendation.dart
    today_state.dart
    viewing.dart
  routing/app_router.dart
  features/
    auth/{data,application,presentation}/
    today/{data,application,presentation}/
    context/{data,application,presentation}/
    watchlist/{data,application,presentation}/
    search/{data,application,presentation}/
    history/{data,application,presentation}/
    preferences/{data,application,presentation}/
```

`data` contains endpoint DTO parsing, repository implementations and feature repository interfaces when test substitution benefits them. `application` holds controllers/providers. `presentation` holds pages and feature widgets. Shared model files describe immutable app values; transport status/error envelope stay in network/data. Where DTO and domain value genuinely coincide, a named `fromJson` constructor is acceptable; do not duplicate every property just to claim Clean Architecture.

Generate folders/files as needed by each phase; no empty enterprise directory tree at P0. Controllers import repository interfaces and models, never Dio. Widgets import controllers/models, never HTTP clients or Supabase APIs. Auth repository is the only frontend feature using Supabase SDK.

## Navigation

Authentication routes: `/sign-in`, `/sign-up`, `/check-email`, `/recover`, `/reset-password`. Authenticated shell uses four tabs: `/today`, `/watchlist`, `/history`, `/profile`. Search `/search` and movie detail `/movies/:tmdbId` are nested destinations reached from Watchlist/History/empty states. Context editor `/today/context`; recommendation details `/recommendations/:id`.

Use go_router stateful shell to preserve tab scroll positions. Default authenticated destination Today. Deep links for verification/recovery are allowlisted and tested. Unauthenticated app cannot render private shell. Auth transition refreshes router and clears private providers. Route IDs never authorize access; API still verifies ownership.

After sign-in, call POST `/me/bootstrap`, then read-only GET `/me`, before the private shell. A bootstrap503 shows retry, not logout. Timezone setup must use an actual IANA identifier from a verified device integration or user selection; Dart `DateTime.timeZoneName` alone can be an ambiguous abbreviation and must not be sent as authoritative. Default UTC remains visible until validated timezone setup succeeds.

Search/Add is a screen, not a fifth tab. No horizontal carousel of suggested movies on Today. Back from context editor returns to prior persisted state unless explicit Save/Pick succeeded.

## Visual direction and reusable UI

Calm cinema-inspired layout: near-black backgrounds, warm light text, one restrained accent, spacious main card. No inherited design system from another project is assumed. Choose exact tokens in P1 and document them; avoid remaking the visual design in every milestone. Use an accessible light theme if needed for device settings, but one polished dark theme is sufficient V1 scope.

P1 tokens (`core/theme/app_theme.dart`): background `#1C1C1C` (kept dominant), surface `#262525`, border white 12%, text `#F5EFE8`, soft text `#D9D1C9`, muted text `#A39B93`, single accent coral `#FF5046` for the selected option and primary action only. Radii: chips 16, buttons 18. Typography: Jost (SIL OFL, bundled static weights) for its geometric, poster-like restraint: 500 headings, 400 body/metadata, 700 for the 19px primary label so white-on-coral qualifies as WCAG large text; 300 only for large placeholder titles. Selection also shows a check icon, never colour alone. The chosen film's artwork runs full width and fades into charcoal; title, metadata and up to two reasons sit as a compact block on the primary action. Genres are a muted text line, not pills.

Today: poster as central visual, title/year, runtime/genres, short reasons and uncertainty, primary Watch Tonight, secondary Already seen and Pick another, context chips and “Why?”. One scrollable page if text grows, without an alternate recommendation list. Buttons remain visible at typical phone height where practical; do not crop descriptions to hide action state.

Reusable widgets: MoviePoster (stable aspect ratio/placeholder), RecommendationCard, RuntimeChip, GenreChips, ContextSummary, ReasonList, AsyncStateView, EmptyState, ErrorPanel, RatingSelector, RejectionSheet, MovieListTile and PrimaryAction. Keep reusable widgets behavior-specific; no configurable giant “universal card.”

Accessibility: meaningful image/action semantics, 48dp touch targets, sufficient contrast, no color-only rating meanings, logical focus order, readable at 200% text scale. No movie-poster binaries bundled in source. UI fixture posters use local geometric placeholders. Exception (ADR 002): the UI-preview build may show developer-supplied posters from the git-ignored `frontend/preview_posters/`; they are never committed.

## State model

TodayController holds `AsyncValue<TodayEnvelope>` plus an independent action status and preserved last successful envelope. Server is authoritative for statuses, versions, current pick and history. Do not optimistically mark watched or reject. Disable in-flight buttons; show action progress without blanking the entire movie card. If mutation fails, retain the last card and show retry/contextual error.

Each deliberate action gets a UUID idempotency key. Keep body/key together through a network retry: after an ambiguous failure (no response, timeout, 5xx) the same command reuses its key (`RetryKeys`), so the server replays; success or a 4xx settles it and the next action gets a new key. After an ambiguous timeout offer Retry with the same key; do not generate a new key automatically. After success or a known validation/conflict failure, the next deliberate action gets a new key.

Version conflict reloads Today and displays “Tonight's choice changed.” Preserve typed note/context in the editor; do not automatically resubmit stale action against a different film. Cached idempotency replay may return an older envelope after other actions; perform GET Today after replay if response version is older than already held state. Never move state backwards.

Repository invalidation rules:

| Success | Refresh/replace |
|---|---|
| Choose, accept, reject, apply context | Apply returned Today; invalidate recommendation history |
| Mark watched | Today, Watchlist, Watched history, recommendation history |
| Manual watched | Same; selected film is cleared as already known watched, never completes Today |
| Add/remove watchlist | Watchlist and returned Today |
| Rate/edit rating | Watched history; keep current choice stable |
| Change recommendation preferences | Preferences and returned Today |
| Unblock | Blocks and returned Today; do not restore archived entry locally |
| Logout/user switch | All private providers plus auth session state |

Background app resume or date transition triggers GET Today, never choose. Use server local_date instead of assuming device timezone/date. Client cannot permanently cache an accepted choice across accounts.

## Screen behavior

### Today / Tonight: context first, then ONE film

Read GET Today on open/resume. New session/no initial context shows an intent selector, not a list of movies: What do you want from tonight's movie? Make me laugh / Keep me hooked / Relaxing / Deep / Exciting / Comforting / Let me feel it / Surprise me. Optional mood can reveal the four down-mood follow-ups; never preselect comedy from sadness. Optional time is inline with Skip/no cap. Current emotion and desired experience are separately modeled and displayed.

Pick my movie sends complete reviewed context through POST choose, applying context and ranking atomically. No separate mandatory Save/Choose screens. In P1 this runs against clearly labeled fake repositories; P4 connects the same flow to the real scorer. An already offered/accepted pick loads directly with saved chips and Edit tonight; re-opening does not ask again or regenerate. Ready after rejection uses saved context.

Render exactly one prominent card: poster,title/year,runtime,genres,one/two factual reasons. Primary Watch Tonight; secondary Already seen and Not feeling it (Already seen, Never recommend and Mark watched are hidden in the normal build until P5 adds viewing history; ADR 006). “Why this film?” beside Edit tonight opens the winner-only drawer: stored reasons plus component points of each weight from GET /recommendations/{id}. No Top picks, horizontal carousels, recommendation grids, adjacent alternatives or swipe-to-re-roll. Keep score math behind Why; this drawer shows winner only. A secondary developer comparison endpoint is never used to add film choices to Tonight.

Under the film's details, “Available on” lists the region's subscription/free providers with logos, rent/buy as a muted line and “Streaming data: JustWatch · <region>”; nothing is shown when unknown, empty or failing (ADR 007). Accepted state shows Mark watched and Change my mind. Completed keeps its one watched card and rating/history links; no new movie. Empty inventory shows Add movies. No match shows aggregate explanation and Adjust context/Add action, never another catalogue. Error retains current card/context draft where safe. API retry button retries GET or the same deliberate command key, never chooses as a side effect of a read.

### Lightweight replacement sheet

Not feeling it offers Not feeling this one / Too long / Something lighter / Different genre / Already watched / Just give me another (Already watched records a past viewing with unknown date; ADR 006 amendment). Simple skip needs no text or questionnaire. Both Not feeling and Just give me another map to temporary not_tonight. Never recommend is separate under More actions, with explicit persistent-block explanation.

Too long shows optional lower cap; Different genre requires selected-film genre IDs; Already seen confirms known viewing/date uncertainty. Direct card Already seen uses the same command/confirmation, without treating it as tonight's completion. Optional Other/note remains in advanced feedback.

Confirm sends one reject with choose_another=true; returned Today contains ONE replacement or pause/no-match. Do not perform a second client choose automatically. Stop for tonight uses false. Keep old card locked while command is in flight, then replace it; never render two actionable choices. Preserve reason/detail input on error and reuse idempotency key on ambiguous timeout.

Third/later rejection returns paused. Show Adjust tonight's context as primary, Continue once as secondary deliberate action (continue_after_pause=true), or Stop. No rapid rolling, infinite swipe gesture or “Refresh.” Changing effective scoring context must be real; emotion-only or profile-overridden no-effect edits cannot bypass the pause. Server compares against last attempted context, so separately saving an actually changed intent still works. Continue does not reset counts.

### Context editor

Basic controls: confirmed desired experience, optional current mood and time. Edit tonight shows them as three compact selector fields (What do you want? / How are you feeling? Optional / How much time? Optional) that open a bottom-sheet list with the current value checked; choosing closes the sheet; mood and time can be cleared (Not set / Any length). The first-run context screen keeps its one-tap choices. Advanced controls: prefer/avoid genre IDs and optional pace/complexity/heaviness targets with coverage caveat. Do not expose fine-grained movie-trait sliders as a launch prerequisite. The full product works with no reviewed traits.

Show parsed proposal/draft and field uncertainty. Emotion-only input opens lightweight desired-effect choices; sad never implies comedy. User may Save context (clear scoring-context-changed active pick without generating) or Pick with this context (atomic choose with context). Replacing accepted film is visibly confirmed. Cancel changes nothing. AI failure retains text and controls. A proposal can never mutate automatically. Profile hard limits remain visible and cannot be weakened by session controls.

### Watchlist/Search

Watchlist pagination and stable rows; List or Poster layout (3-column grid, 2 when very narrow; device-local preference). Remove by swiping a list row right (threshold, snap-back below it, no dialog) or long-pressing a poster, with an immediate Undo; a failed removal restores the row and explains; screen readers get a Remove action (ADR 005). Search result rows are one line of poster | details | action: a compact “Add” (screen readers hear “Add <title> to watchlist”) or a non-primary “In watchlist” on the right, centred on the poster; “Not released yet” stays in the details; at large text the action stacks under the details. Search debounce300ms, minimum2 characters, page-by-page results. Cancel older HTTP query or discard responses with old query sequence. Runtime unknown until detail fetch; no N+1 runtime calls. Show duplicate-add as already saved. Loading-more failure keeps existing items with inline retry. Empty search and empty watchlist use different copy.

### History

Watched/Recommendations segments and pagination. Ratings use four labeled buttons, not ambiguous stars. Skip is explicit. Rating edit sends current viewing version; conflict reloads record. Unknown watch date displays “Date unknown · recorded …”. Accepted but unfinished records are visibly different from watched.

### Profile

Genre preference controls map to documented values; advanced strength slider optional. Blocked genres separate from preference strength. Defaults and timezone visible. AI opt-in explains that current sentence is sent to configured parser, not movie history. About includes approved TMDB attribution. Sign-out clears private state even if provider call fails; explain pending network sign-out if needed.

## API client boundary

One Dio instance configured from AppConfig, bearer attached from current auth session. No hardcoded secrets/URLs in widgets. Requests use API_CONTRACT exactly. Map envelope into typed ApiError with code/message/retryability. DTO validators detect missing required fields; malformed response is a visible error, not an empty successful list.

SDK handles refresh. On401, perform one coordinated refresh then retry original request once (same idempotency key); concurrent requests share refresh operation. On refresh failure clear private state and route sign-in. Never infinite refresh loops. Read timeout30 seconds allows backend provider budget; cancellation and query sequences prevent stale Search state.

GET network retries: at most one when safe and retryable. Mutation retry remains explicit or uses preserved key; no blind new-key retries.429 honors Retry-After via a visible cooldown. Error messages come from known safe backend envelope with local fallbacks, not raw HTML/body. Redact authorization in debug interceptors; production never logs request bodies.

## Loading/empty/error conventions

Initial page load: bounded skeleton. Refresh: keep data with small indicator. Action: spinner on affected button, disable duplicate taps. Empty: reason + one next action. Error: plain cause + permitted retry without discarding input. Dependency-down search does not label watchlist empty. Failed mutation does not optimistically remove film.

## Tests and manual gates

Unit: model parsing/nulls, repository endpoint/headers/body, structured draft merging, idempotency key reuse, auth refresh fan-in. Widget: every Today state, accept is not watched, rejection detail requirements, uncertainty display, context proposal requires an explicit Save/Pick, stale version retains note, no alternate feed or actionable runner-up cards, large text/placeholder layout. Integration: login->bootstrap->search->add->context->one pick;reject-with-replacement->one different pick;watch->rate->history->next-day score test via backend fixed-clock fixture. Device normal time cannot be altered by a production test endpoint.

P1 fake repositories expose deterministic scripted states in an explicitly selected UI-preview build only. Real integration must replace fake repositories in normal app configuration; no silent fallbacks to fake success when backend fails.

## Required product tests

A500-movie fake inventory still produces exactly one actionable movie card. Sad+Comfort and Sad+Let me feel it remain distinct intents; changing only current_mood cannot change ranks. Surprise me requires no emotion inference and is deterministic. Assert no candidates/alternatives from Today are rendered; comparison DTOs cannot become primary-screen movie actions. Test atomic initial context/choose and replacement (one server command), third rejection pause, explicit Continue once and unchanged-context guard.
