# Cinemé — product specification

Version 1.1. Normative V1 product behavior. See CRITICAL_REVIEW for corrections to the initial idea.

## Vision and success

Cinemé removes movie-choice paralysis: the user supplies lightweight context and receives ONE movie from their watchlist. Hundreds of saved films are internal candidates, never a Tonight recommendation feed. Working tagline: “One pick. No scrolling.” The main task is choosing a movie to watch, not browsing recommendations.

The portfolio demo must show an end-to-end authenticated flow, a score breakdown, scope-correct rejection, post-watch learning, no-match handling, and an optional natural-language context proposal. A beautiful card alone is not completion.

## Exact V1 scope

- Flutter Android app, developed on Windows. Other targets may compile but are not release acceptance targets.
- Supabase email/password signup, verified sign-in, sign-out and password recovery.
- TMDB movie search and details through FastAPI; internally managed watchlist.
- Maximum 500 active watchlist entries per account; archived entries preserve history.
- One on-demand persisted daily recommendation, plus explicit replacements after rejection or context edit.
- Explainable deterministic scorer; versioned weights and a bounded winner/comparison record.
- Lightweight current mood, desired viewing experience, optional runtime and genre context; pace/complexity/heaviness are optional enrichment controls; optional natural-language interpretation via local Ollama.
- Distinct accept, reject, mark watched and rate actions.
- Viewing history, recommendation history, editable ratings, movie blocks and basic genre preferences.
- Local-date behavior using an account's IANA timezone; all timestamps stored in UTC.
- Tests, CI, server logs, database migrations, deployment and a documented reproducible demo.

## Non-goals

No TV *(revised by [ADR 011](docs/adr/011-shows-and-anime-next-episode.md): shows and anime series are a second media type, still one recommendation per night, standard order, regular seasons only, no specials, no playback or episode feeds)*, social features, collaborative filtering, neural recommendation training, embeddings, chat assistant, autonomous agent, streaming playback, guaranteed availability, platform pricing, provider subscription management, push notification, nightly job, scraped watchlist, import UI, offline mutation sync, public review platform or analytics dashboard. No actor/director affinity in V1. No inferred permanent dislike from a temporary refusal.

## Product invariants

| ID | Required behavior |
|---|---|
| I01 | Every selected movie belongs to that user's active watchlist at selection time. |
| I02 | Watched movies, blocked movies and ineligible metadata never enter the ranked set. |
| I03 | Hard runtime and genre constraints are enforced before scoring; no silent relaxation. |
| I04 | At most one current recommendation record exists per daily session. It can be a no-match result. |
| I05 | Reloading Today does not select another movie or make an LLM call. |
| I06 | Accepting “Watch Tonight” does not create viewing history or a positive rating. |
| I07 | Tonight-only rejection cannot change long-term genre affinity. |
| I08 | Post-watch rating edits replace prior learning evidence; they never accumulate duplicate votes. |
| I09 | A movie offered earlier in the same session is excluded from later selections that day. |
| I10 | The scorer has no network, database, LLM, clock or random-number access. |
| I11 | Identical full test fixtures and engine/configuration produce identical rankings; saved winner/top comparisons explain retained scores without claiming full production-run replay. |
| I12 | AI cannot choose a movie, change weights, mutate preferences or weaken a hard constraint. |
| I13 | Unknown movie traits are displayed and scored as unknown, not invented. |
| I14 | All private-resource access is scoped to the verified user, including histories and explanations. |
| I15 | Mutations are atomic, version-checked where specified and safe to retry with the same key. |
| I16 | Failures are visible; the UI never displays a success from an uncommitted server mutation. |
| I17 | The engine may rank hundreds of candidates, but Tonight exposes only ONE actionable movie choice at a time. |

## Screens and flows

### Authentication and setup

On first launch sign in or register. Registration may return “Check your email” without a session. Use Android app-link/deep-link configuration for verification/recovery. Returning users resume a valid SDK session; refresh failure returns to sign-in without showing another user's cached content.

After Supabase sign-in, POST `/api/v1/me/bootstrap` explicitly creates/reuses a profile and default preferences; GET `/api/v1/me` is read-only. The profile starts with timezone `UTC` until the user supplies a validated device IANA timezone. Setup asks for optional preferred genres and timezone. No mandatory taste questionnaire. Empty watchlist leads directly to Search/Add. The user can log an already watched film from movie details to seed history.

### Today / Tonight

The default destination is a lightweight context-first experience, followed by one prominent film. Ask “What do you want from tonight's movie?” with Make me laugh, Keep me hooked, Something relaxing, Something deep, Something exciting, Something comforting, Let me feel it and Surprise me. Current mood is optional and separate; if the user selects Feeling down, offer Cheer me up / Something comforting / Let me feel it / Surprise me. Optional time follows inline, not a mandatory questionnaire. “Surprise me” skips inference and uses the same deterministic scorer.

The single primary context CTA is “Pick my movie.” It sends the reviewed structured context and chooses atomically. There is no additional Apply-then-Choose obstacle in this primary flow. If a current pick already exists today, show it immediately with saved context chips and an Edit tonight link; do not interrogate the user again or regenerate on reload. Empty inventory leads to Add movies before context selection.

After selection show exactly one poster, title/year, runtime, genres and one or two short factual reasons. Primary action: Watch Tonight (or Watch This). Secondary: Already seen and Pick another. Why? is a secondary detail drawer, not a top-candidates gallery. No carousel, Top picks for you, recommendation grid or adjacent alternatives. Runtime/genre facts and modest explanation suffice; score percentages do not belong on the main card.

States: loading; needs lightweight context; ready to pick using saved context; offered; accepted; completed; paused; no match; empty inventory; service error. GET only reads. A new day asks for tonight's context, optionally choosing Surprise me, then generates on the explicit Pick my movie action. Existing accepted/offered pick stays stable across resume.

Watch Tonight records intent and changes actions to Mark watched / Change my mind. Only Mark watched creates tonight's completion and opens optional Loved/Liked/Okay/Disliked rating. Already seen records known prior viewing without claiming tonight complete. Completed Today keeps its card and History link; no second-film generation that date. No streaming playback/availability promise.

### Replacement / Not feeling it

Pick another opens a compact reason sheet: Not feeling this one, Too long, Something lighter, Different genre, Already seen, or Just give me another. Reasons are lightweight; no free-text explanation is mandatory. “Just give me another” maps to temporary `not_tonight`, not dislike. The permanent Never recommend control remains available in secondary More actions, separate from everyday replacement.

A confirmed replacement is one deliberate user action. The client sends idempotent reject with `choose_another=true`; the backend atomically records the feedback and selects ONE replacement under the resulting context. Stop for tonight uses `choose_another=false` and clears the choice without selecting. Direct Already seen on the card confirms the recording and requests one replacement in the same way. No moment exposes two actionable movie cards.

On the third rejection in that session, clear the choice and pause instead of auto-selecting a fourth. Ask the user to adjust tonight's context; a deliberate Continue once action may request exactly one more film, with `continue_after_pause=true`. Later replacement requests remain paused until explicitly continued or effective scoring context actually changes. No swipe gesture, rapid re-roll animation, endless auto-replacement or meaningless Refresh label. The server's 20-attempt/day cap remains an abuse safeguard, not a UX target; GET/replays/returning a stable pick do not count.

Advanced context editing supports Save (clear a scoring-context-changed current pick without choosing) and explicit Pick with this context (atomic choose). Accepted-pick replacement requires visible confirmation. Natural-language proposals always remain editable and require an explicit action before affecting selection.

### Watchlist

Paginated saved movies with title/year/poster, optional runtime, date added, and an explicit remove action. Search/filter inside the list is permitted. This list is inventory, not a ranked recommendation feed. Keep Add/Remove/Inspect as its purpose; do not promote Watchlist browsing as the main way to pick tonight. Imports remain future scope, although future import actions belong here. Adding a duplicate is a success returning the existing row. Removing archives the entry. Restoring a removed entry resets `added_at` to the restoration time.

Removing or blocking the current pick supersedes it and clears the current selection; accepted picks are not immune. Watched history always prevents re-recommendation in V1. Undoing a watch is not implemented; the UI must confirm the action before recording it.

### Search / Add

Nested route accessed from Watchlist or empty state. Debounced TMDB movie search; title/year disambiguation; movie details load runtime. “Add to watchlist” and “Already watched” are separate actions. No results, missing poster, upstream error and duplicate entry have distinct states. Adult-flagged items cannot be added in V1. Upcoming and unknown-date films can be saved, are labelled “Not released yet”, and Tonight cannot pick them until a known release date has passed (ADR 005).

### History

Two segments: Watched and Recommendations. Watched shows completion date and optional rating, allowing rating correction. Recommendation history shows offered/accepted/rejected/watched/superseded/no-match records and their reasons/context. Explainability is accessible for an owned record. “Already watched” records a known watched film, not proof that it was watched tonight.

### Profile / Preferences

Optional display name; preferred genre scores; default runtime cap; blocked genres; timezone; blocked movie list with unblock; AI opt-in toggle; TMDB attribution/About; sign-out. No cloud credentials entered in the app. Provider selection is backend configuration, not a settings screen. Permanent preference changes invalidate the current choice; they do not auto-select a replacement.

## Feedback semantics

| Reason code / label | Tonight effect | Permanent effect |
|---|---|---|
| `not_tonight` | Exclude this movie for the session | None |
| `too_long` | Exclude movie; optionally apply a user-entered shorter cap | None |
| `wrong_genre` | Exclude movie; user chooses at least one of its genre IDs to avoid tonight | None |
| `too_serious` | Exclude movie; set `heaviness_max=0.35` | None |
| `want_lighter` | Exclude movie; set `heaviness_max=0.35`, `desired_experience=relax` | None |
| `already_watched` | Reject and exclude; create viewing if not present | Watched exclusion, no inferred rating |
| `never_recommend` | Exclude | Reversible user/movie block; archive active entry |
| `other` | Exclude movie; retain optional note for user history | No automatic inference |

`too_long` does not guess a numeric cap. If no new cap is entered, only the film is excluded. If entered, it must be lower than the existing cap when one exists. `wrong_genre` does not automatically reject all genres in a multigenre film. `other` text is not automatically sent to an LLM or used to change taste. A separate “Interpret as tonight's context” action may prefill the context editor; the user must explicitly Save/Pick.

Post-watch ratings: `loved`, `liked`, `okay`, `disliked`; optional null. They are long-term genre evidence. Disliked does not automatically block all related genres or add a movie block. Block/unblock is explicit.

## Recommendation behavior

The ranked set is limited to the active watchlist. Only the selected movie is exposed by Today; internal rank order and bounded debugging comparisons never become actionable alternatives there. Filter first, score second. No minimum-score threshold in V1: if eligible candidates exist, return the deterministic highest-ranked movie, while stating weak/unknown context matches honestly. If none exist, persist a no-match attempt with exclusion counts. Never fill the empty set from TMDB discovery.

One daily session is keyed by `(user_id, local_date)`. Date uses the current profile timezone at session lookup. A timezone edit affects subsequent lookups and may open a different date; the UI explains this. Existing session snapshots keep their original timezone and calculated day-end for audit; exclusions follow session identity, not a competing TTL after timezone changes. Same-date lookup reuses its session. Recommendations do not regenerate in the background at midnight. An old accepted movie remains visible in History, while Today loads the new day's session.

Today's accepted/offered choice remains stable even if metadata refreshes globally. Explicit invalidation occurs on watchlist removal, blocking, preference edit, effective scoring-context edit, or manually recording that selected film as already watched elsewhere. That manual logging supersedes/clears the choice; it never claims tonight's plan was completed. Only the recommendation's deliberate Mark watched action completes Today. Ordinary adding to watchlist and rating another film do not replace the current pick. New selection uses current data and learned affinities. Once completed, Today retains its watched card; preference/inventory edits apply to future selections without clearing or reopening the completed session.

## Context and uncertainty

`current_mood` describes optional emotion: `down`, `tired`, `okay`, `upbeat` or null. `desired_experience` describes intent: `make_me_laugh`, `comfort`, `feel_it`, `relax`, `deep`, `exciting`, `keep_me_hooked` or `surprise`. The user must choose an intent or explicitly use Surprise me before an initial pick. Current mood alone never selects an intent, genre, pace or complexity limit. Changing only emotion updates session metadata/version but preserves the current pick and cannot bypass the rejection pause. Feeling sad does not imply comedy. The same mood with Comfort versus Let me feel it may produce different scores.

Runtime cap is inclusive. Under two hours ->119; two hours or less ->120. About90 ->proposed90 with editable tolerance. Time is optional. Hard runtime and blocked/avoided genres combine with permanent preferences using minimum cap and union of exclusions. Remove blocked IDs from effective preferred genres and report overrides; edit Profile to loosen a permanent rule.

Genre-based desired-experience matching is an explicitly approximate signal. Reliable comfort/relaxation cannot be guaranteed from genre. Optional reviewed pace/complexity/heaviness may improve soft context matching when available; an empty curated dataset is a fully supported baseline. Unknown requested traits contribute0.5, with no weight redistribution and no invented values. Keep enhancement controls in Advanced, not the main launch questionnaire. Do not claim the app works “extremely well” without evidence of user outcomes.

## Failures and edges

- Zero saved movies: Search/Add CTA, no provider call for recommendation.
- One eligible movie: may return it despite low recency/diversity scores; if already offered today, no match.
- Missing runtime: allowed without cap; excluded with cap; display “Runtime unavailable.”
- Missing genres/traits/ratings: neutral signals, explain uncertainty. Never treat null as zero runtime.
- External API down: existing cached watchlist and deterministic recommendations still work; search/new uncached add fail visibly.
- LLM unavailable/invalid/slow: retain typed text and structured controls; never block scoring.
- Poster fails: fixed-size placeholder; no card jump.
- Concurrent edits: return conflict and refresh session; do not overwrite silently.
- Repeated taps/retries: idempotent mutation; no duplicate feedback/history.
- All remaining films too long: report count and explicit edit action; no suggested cap automatically applied.
- Rejected/accepted stale card from another device: conflict, refresh, keep user-entered note until resolved.
- Local date changed while a sheet is open: old session action gets `SESSION_EXPIRED`; refresh Today and require a new explicit action.
- Logout/account switch: clear private in-memory state and stored API response caches.

## Privacy, attribution and release

Store only needed account preferences and movie interactions. Do not log raw context, email, tokens, passwords or rejection notes. AI is opt-in; send the current sentence and minimal schema, never the full history. No retention of raw prompts after parsing; store only accepted structured context. Rejection notes are private and capped at 500 characters.

About must display approved TMDB logo and the notice: “This product uses the TMDB API but is not endorsed or certified by TMDB.” TMDB data is used under its applicable developer terms for this noncommercial portfolio project; commercialization is a separate licensing decision. Do not publish third-party poster files inside the repository. A closed portfolio demo is V1's release scope, with an operator account-deletion procedure; self-service account deletion/export is required before a broader public product launch.

## Future, explicitly outside V1

CSV preview/resolve/commit importer; Letterboxd export adapter; authorized provider integrations; rewatches; actor/director affinity; reliable trait-enrichment review tooling; validated LLM explanation wording; streaming availability as a filter or ranking signal (V1 shows display-only availability per region, ADR 007); push reminders; online experiments and weight tuning; offline support; web/iOS release; social features only after proving the one-choice product.

## Storage boundary

Keep the winner, engine/config version and snapshot/hash, requested/effective context, winner breakdown/display snapshot, exclusion counts and at most nine scored runners-up (ten retained films total). No per-candidate audit table, full production RankingInput archive or two-MiB snapshots. Full replay fixtures live in tests; production comparisons are bounded and secondary to the one-choice UI.
