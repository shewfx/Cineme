# Cinemé — REST API contract

Version 1.1; application prefix `/api/v1`. All application endpoints except health require verified bearer JWT. Movie endpoints also require auth to prevent an open proxy. JSON uses snake_case; UUIDs as strings; instants ISO-8601 UTC; local dates YYYY-MM-DD. Null fields below are intentionally nullable, not omitted arbitrarily. FastAPI/Pydantic generate OpenAPI from matching schemas; commit a contract snapshot at P3.

## Common rules

- No request accepts user_id. Identity comes from the verified JWT.
- Call POST `/me/bootstrap`, then read-only GET `/me`, after authentication before other application endpoints. Missing app profile returns409 `PROFILE_NOT_INITIALIZED`; bootstrap itself returns403 `EMAIL_NOT_VERIFIED` for an unconfirmed identity. Infrastructure failure during bootstrap does not sign the client out.
- All private POST/PATCH/DELETE mutations require UUID `Idempotency-Key`, except POST me/bootstrap (naturally idempotent transactional identity upsert) and context parse (no mutation). Missing/invalid key ->400 `IDEMPOTENCY_KEY_REQUIRED`. Replay identical committed mutation for 24h; different request/route using same key ->409 `IDEMPOTENCY_CONFLICT`.
- Session mutations use `expected_session_version`. Zero means “no session exists yet”; >0 must match today's existing session. Preference/viewing PATCH uses `expected_version`.
- Unknown request fields rejected with 422; API never silently ignores a misspelled runtime/feedback field.
- List pagination: `limit` default20, max50, optional opaque `cursor`. Responses `{items:[...],next_cursor:null|"..."}`. Cursors are scoped/validated server-side; no client SQL or IDs used as authorization. Sorts are explicitly documented below.
- Max body32KiB for user-facing commands, parser text1..500 characters, note <=500. Rate limits may return429 with `Retry-After`.
- A no-match recommendation is a successful domain result, not an HTTP error.
- Optional `X-Request-ID` is validated or replaced; response always returns request ID header. JWT/raw payloads are not echoed in errors.

Error shape for every non-2xx application response, including validation:

```json
{
  "error": {
    "code": "VERSION_CONFLICT",
    "message": "Tonight's plan changed. Refresh and try again.",
    "details": {
      "current_version": 4
    },
    "retryable": false
  },
  "request_id": "opaque-id"
}
```

Major common errors: 401 `AUTH_REQUIRED`/`TOKEN_INVALID`; 404 `NOT_FOUND` for nonexistent/not-owned resources; 409 `VERSION_CONFLICT`/`SESSION_EXPIRED`/`INVALID_TRANSITION`/`IDEMPOTENCY_CONFLICT`; 422 `VALIDATION_ERROR`; 429 `RATE_LIMITED`/`DAILY_ATTEMPT_LIMIT`; 502 `UPSTREAM_INVALID_RESPONSE`; 503 `DEPENDENCY_UNAVAILABLE`/`DATABASE_BUSY`. No stack traces/upstream secret bodies in client responses.

## Domain response shapes

### MovieSummary / MovieDetails

```json
{
  "tmdb_id": 104,
  "title": "Run Lola Run",
  "year": 1998,
  "runtime_minutes": 81,
  "vote_average": 7.4,
  "genre_ids": [
    28,
    18,
    53
  ],
  "genres": [
    {
      "id": 28,
      "name": "Action"
    },
    {
      "id": 18,
      "name": "Drama"
    },
    {
      "id": 53,
      "name": "Thriller"
    }
  ],
  "poster_url": null,
  "can_add": true,
  "released": true
}
```

MovieSummary carries nullable `vote_average` (TMDB community rating, display-only; null when unknown or not cached, so search results leave it null). MovieDetails extends summary with `release_date`, `overview`, `original_title` (null when equal to title), `original_language`, `vote_count` (TMDB metadata, display-only, never ranking input; ADR 004), `metadata_fetched_at`, `stale`, `traits:{pace:null|number,complexity:null|number,heaviness:null|number,source:null|"curated_v1"}`. Runtime is null on TMDB search unless genuinely known from cache; do not make N detail requests per search page. `can_add=false` only for adult or unavailable items; upcoming and unknown-date films can be saved (ADR 005). `released` is true only when `release_date` is known and on or before the user's local date; Tonight eligibility requires it (engine `movie_unavailable`). Add revalidates. Title/year/source test fixtures are not copied live vote data.

### SessionContext (complete accepted context, no text)

```json
{
  "current_mood": "tired",
  "desired_experience": "exciting",
  "max_runtime_minutes": 100,
  "pace": "high",
  "complexity_max": 0.45,
  "heaviness_max": null,
  "prefer_genre_ids": [],
  "avoid_genre_ids": []
}
```

current_mood nullable enum down/tired/okay/upbeat, used only for optional follow-up, never scores. desired_experience required for accepted context: make_me_laugh/comfort/feel_it/relax/deep/exciting/keep_me_hooked/surprise. Surprise is a deliberate user choice and omits intent match rather than randomizing. Parser draft may have desired_experience=null when clarification needed; that draft cannot be submitted as accepted context until user chooses.

Other scalars nullable; runtime integer1..600, pace low/medium/high, soft trait targets0..1. Distinct genre ID lists <=20, prefer/avoid disjoint. Time and advanced traits are optional. Profile cap/block applies minimum/union and removes blocked preferred IDs, with overridden_fields. Emotion does not imply a desired effect, genre or trait setting. Sparse optional traits never prevent ranking.

### RecommendationSummary

```json
{
  "id": "uuid",
  "status": "offered",
  "movie": {
    "tmdb_id": 104,
    "title": "Run Lola Run",
    "year": 1998,
    "runtime_minutes": 81,
    "genre_ids": [
      28,
      18,
      53
    ],
    "genres": [
      {
        "id": 28,
        "name": "Action"
      },
      {
        "id": 18,
        "name": "Drama"
      },
      {
        "id": 53,
        "name": "Thriller"
      }
    ],
    "poster_url": null,
    "can_add": true
  },
  "total_score": 74.33,
  "engine_version": "weighted_v1",
  "explanation": "81 minutes, within your 100-minute limit.",
  "reasons": [
    {
      "code": "fits_runtime",
      "values": {
        "runtime_minutes": 81,
        "cap_minutes": 100
      },
      "source": "metadata"
    }
  ],
  "uncertainties": [],
  "created_at": "2026-10-01T22:20:00Z",
  "no_match_summary": null
}
```

Each reason/uncertainty object also carries `text`, the deterministic template sentence stored with the run (ADR 006). Examples abbreviate nonessential nested values; real genres must match genre IDs. No-match has movie/total_score null, status no_match, explanation of exclusions and `no_match_summary:{candidate_count:3,primary_exclusion_counts:{runtime_exceeded:2,offered_this_session:1},suggested_actions:["edit_runtime","add_movies"]}`. Suggested actions are labels, never implicit mutations or guessed new numeric limits.

### TodayEnvelope

```json
{
  "state": "offered",
  "local_date": "2026-10-02",
  "session": {
    "id": "uuid",
    "version": 2,
    "timezone": "Asia/Kolkata",
    "context": {
      "max_runtime_minutes": 100,
      "pace": "high",
      "complexity_max": 0.45,
      "heaviness_max": null,
      "prefer_genre_ids": [],
      "avoid_genre_ids": [],
      "current_mood": "tired",
      "desired_experience": "exciting"
    },
    "effective_context": {
      "max_runtime_minutes": 100,
      "pace": "high",
      "complexity_max": 0.45,
      "heaviness_max": null,
      "prefer_genre_ids": [],
      "avoid_genre_ids": [],
      "current_mood": "tired",
      "desired_experience": "exciting"
    },
    "overridden_fields": [],
    "rejection_count": 0,
    "attempt_count": 1,
    "completed_at": null
  },
  "recommendation": {
    "id": "uuid",
    "status": "offered",
    "movie": {
      "tmdb_id": 104,
      "title": "Run Lola Run",
      "year": 1998,
      "runtime_minutes": 81,
      "genre_ids": [
        28,
        18,
        53
      ],
      "genres": [
        {
          "id": 28,
          "name": "Action"
        },
        {
          "id": 18,
          "name": "Drama"
        },
        {
          "id": 53,
          "name": "Thriller"
        }
      ],
      "poster_url": null,
      "can_add": true
    },
    "total_score": 74.33,
    "engine_version": "weighted_v1",
    "explanation": "81 minutes, within your 100-minute limit.",
    "reasons": [],
    "uncertainties": [],
    "created_at": "2026-10-01T22:20:00Z",
    "no_match_summary": null
  },
  "viewing": null,
  "follow_up": null
}
```

`viewing` is populated for a completed Mark watched choice and includes its optional rating. `follow_up` is the most recent unresolved accepted recommendation from an earlier user-local calendar date and includes its accepted local date. A `not_yet` answer suppresses that prompt until a later local date.

Use full RecommendationSummary in actual responses; movie=null is valid only for no_match, not offered. States: `not_started`, `ready`, `offered`, `accepted`, `completed`, `paused`, `no_match`, `empty_watchlist`. Derive in this precedence: completed session ->completed; offered/accepted pointer ->matching state; no_match pointer ->no_match; no active watchlist ->empty_watchlist; absent session ->not_started; existing no-pointer session with >=3 rejections ->paused; otherwise ->ready. No session means session/recommendation null and expected version0. Never return “offered” without a movie. Every mutation affecting Today returns the current envelope where specified.

## Identity API: delegated, not reimplemented

| Operation | Provider path (Supabase project URL) | App request/result | Major errors |
|---|---|---|---|
| Register | POST `/auth/v1/signup` via SDK | Email/password ->user plus nullable session; confirmation may be required | Provider validation/rate limit/email errors |
| Sign in | POST `/auth/v1/token?grant_type=password` via SDK | Email/password ->SDK session | Invalid credentials/unverified email |
| Refresh | POST `/auth/v1/token?grant_type=refresh_token` via SDK | SDK refresh token ->rotated session | Expired/revoked refresh; return to login |
| Sign out | POST `/auth/v1/logout` via SDK | Clear local credentials/state; revoke applicable refresh session | Network failure must still clear local secrets |
| Recovery | POST `/auth/v1/recover` via SDK | Email and allowlisted redirect ->generic check-email state | Throttle/delivery; do not enumerate users |
| Update recovered password | PUT `/auth/v1/user` via SDK recovery session | New password ->success, then normal login/session | Invalid recovery link/weak password |

Provider wire contracts remain provider-owned; use the SDK rather than homemade forms for token requests. No FastAPI `/auth/login` or `/auth/register` facade. Portfolio tests verify SDK integration, JWT verification and data isolation. Sign-out does not instantly revoke already-issued access tokens; configured short access expiry limits that window.

## Profiles and preferences

### POST `/me/bootstrap`

Purpose: explicitly initialize the verified identity's app profile/default preferences. Request `{}`; no user_id and no idempotency key required. Verify JWT and provider email confirmation outside DB transaction on first initialization, then transactionally insert user/preferences with unique-key conflict handling. Response201 `{profile:MeResponse,created:true}` when created;200 same profile with created=false when it already exists. Concurrent calls safely converge. Existing profile fields are never reset by a retry. Errors401 invalid identity,403 EMAIL_NOT_VERIFIED,503 dependency/DB failure. This is the only initialization endpoint; GET cannot create records.

### GET `/me`

Read-only profile/default preferences. Response200:

```json
{
  "id": "uuid",
  "display_name": null,
  "timezone": "UTC",
  "country_code": null,
  "region": null,
  "created_at": "2026-10-01T22:00:00Z",
  "onboarding_completed_at": null,
  "preferences": {
    "version": 1,
    "genre_preferences": {},
    "blocked_genre_ids": [],
    "default_max_runtime_minutes": null,
    "ai_context_enabled": false
  }
}
```

`country_code` is the user's chosen streaming region (ISO 3166-1 alpha-2) or null; `region` is the effective one: the chosen code, else the one implied by the timezone, else null (ADR 007). `onboarding_completed_at` is null while the account still needs first-run onboarding and a timestamp afterwards; accounts that existed when it was introduced carry their creation time (ADR 010). Clients treat an absent field as completed. 409 PROFILE_NOT_INITIALIZED if bootstrap has not succeeded; standard auth/DB errors. It never inserts or resets anything.

### PATCH `/me`

Request `{display_name:"Shew",timezone:"Asia/Kolkata"}`; any of `display_name`, `timezone`, `country_code`, `onboarding_completed`, unknown fields rejected. `onboarding_completed` accepts only `true` (ADR 010): it sets `onboarding_completed_at` once, a repeat succeeds without changing the original timestamp, and `false`/`null` are 422. Requires idempotency key. Response200 updated profile. Timezone IANA validation; explain possible daily-date change. Editing display name/timezone does not rewrite old session snapshots. No version parameter because fields are simple explicit last-write values, not read-modify-write state.422 invalid zone/name.

### GET `/movies/{tmdb_id}/availability` and GET `/watch/regions`

Display-only availability (ADR 007). 200 `{tmdb_id, region:null|"IN", link:null|"https://www.themoviedb.org/...", streaming:[{id,name,logo_url}], free:[...], rent:[...], buy:[...], fetched_at, stale}` for the caller's effective region (PATCH /me `country_code`, else the timezone's country, else null with empty lists). JustWatch data via TMDB, cached per film 24 h; stale data with `stale:true` during upstream failure; 503 when nothing is cached; 404 unknown film. Never used by ranking. `GET /watch/regions` → `{items:[{code,name}]}`. `PATCH /me` also accepts `country_code` (ISO 3166-1 alpha-2 or null); GET/PATCH /me return `country_code` and effective `region`.

### GET `/me/preferences`

Response200 preferences shape above.

### PATCH `/me/preferences`

Partial fields plus required expected version:

```json
{
  "expected_version": 1,
  "genre_preferences": {
    "35": 0.6,
    "28": 0.4
  },
  "blocked_genre_ids": [
    27
  ],
  "default_max_runtime_minutes": 120,
  "ai_context_enabled": true
}
```

Genre map/lists replace the whole supplied field; omitted fields unchanged; null clears only runtime cap. Response200 `{preferences:{...},today:{...}}`. For an uncompleted session, supersede/clear today's current pick if recommendation-affecting fields changed (genre preferences,blocks,cap), increment session version. Completed session/card remains unchanged; new preferences affect future selections. AI toggle alone does not invalidate. Errors409 version;422 bad genres/values.

### GET `/me/blocks`

Paginated `{items:[{movie:MovieSummary,blocked_at:"..."}],next_cursor:null}` newest block first then movie ID descending.

### DELETE `/me/blocks/{tmdb_id}`

Explicit unblock, idempotency key. Response200 `{unblocked:true,watchlist_restored:false,today:TodayEnvelope}`; absent block succeeds. Does not re-add archived entry. Invalidate cached no-match pointer if necessary; existing offered/accepted pick stays stable when only expanding eligibility.

### POST `/me/blocks/{tmdb_id}`

Explicit persistent Never recommend, idempotency key. Response200 `{blocked:true,already_blocked:boolean,today:TodayEnvelope}`. Block is per-user, hard-excluded by eligibility and creates no rating/history evidence.

## Movies and metadata

### GET `/genres`

Versioned genre registry response200 `{items:[{id:35,name:"Comedy"},...],version:"tmdb_genres_v1"}`; no app DB mutation.

### GET `/movies/search?q=arrival&page=1`

Search title length2..100, page1..500. Response200 `{page:1,total_pages:...,results:[MovieSummary,...]}`. TMDB controls actual pages; expose at most500. No results is200 empty array.422 query/page,429 upstream throttle,503 unavailable. Search's runtime may be null.

### GET `/movies/trending`

Onboarding discovery (ADR 010 amendment). Auth and profile required; no parameters. Response200 `{results:[MovieSummary,...],in_watchlist:[tmdb_id,...]}`: at most 12 films from TMDB's weekly trending list, in TMDB's order, one page and no cursor. Trending means what is popular this week for everyone; it is **not** personalized and **not** a recommendation, never scores or ranks anything, and is not used by Tonight. The same TMDB list is served to every user (cached in the provider for one hour; a failed refresh serves the last good copy), then filtered for this caller using the search eligibility rules plus the add rules: adult films, films without a known release date on or before the caller's local date, and films without a poster are omitted; films this caller already watched or blocked are omitted (an Add would fail). `can_add` is true and `released` is true for every item; `runtime_minutes` is null (details are not fetched); `vote_average` is included. `in_watchlist` lists the returned films already on the caller's active watchlist. Read-only: it writes nothing for the caller (the shared metadata cache is not touched either). Errors: 401, 409 PROFILE_NOT_INITIALIZED, 502 on a malformed upstream list, 503 retryable when TMDB is unavailable and no cached list exists, 429 on upstream throttling. The route is registered before `/movies/{tmdb_id}`.

### GET `/movies/{tmdb_id}`

Fetch/cache details on demand. Response200 MovieDetails with stale flag.404 upstream film not found;503 first fetch unavailable. This GET can refresh/populate shared metadata cache, but never private watchlist/history. Stale usable details return200 stale=true on refresh failure.

### POST `/movies/{tmdb_id}/refresh`

Explicit shared metadata refresh; `{}` and key required.200 `{movie:MovieDetails,refreshed:true|false}`. One-hour per-movie minimum interval returns429; ordinary client does not poll this endpoint. Freshness failure with old cache returns refreshed=false/stale=true. Does not silently change a current recommendation; newly selected films use refreshed metadata.404/503 when no valid prior cache. Any private response is still scoped to caller.

## Watchlist

### GET `/watchlist?limit=20&cursor=...&sort=added_desc`

Active entries in the requested `sort`; default `added_desc` (added_at DESC,id DESC). `sort` is one of `added_desc`, `added_asc`, `title_asc`, `title_desc` (case-insensitive title), `year_desc`, `year_asc` (release year, then title A-Z) and `runtime_asc`, `runtime_desc` (runtime, then title A-Z). Unknown year or runtime always sorts last in both directions; every order ends in the entry id so it is total. Sorting and keyset pagination are server-side, so page boundaries never reorder films. The opaque cursor is bound to the sort that produced it: a cursor from another sort, or an unknown `sort`, returns 422. Sorting never changes membership or preferences.

Response: 200 `{items:[{id:"uuid",movie:MovieSummary,added_at:"...",source_type:"manual"}],next_cursor:null}`. Optional `q` length1..100 searches cached title for this user's list, case-insensitive; no external request.422 invalid cursor/filter.

### POST `/watchlist`

Request `{tmdb_id:104}`; metadata fetch outside private transaction.201 `{entry:{...},already_present:false,today:TodayEnvelope}` (`today` present from P4; ADR 004); duplicate active returns200 same entry/already_present=true. Removed eligible entry restores and resets age. Validates adult flag and runtime normalization; upcoming/unknown-date films are saved with `released=false` (ADR 005).409 `MOVIE_ALREADY_WATCHED`, `MOVIE_BLOCKED`, `WATCHLIST_LIMIT`;422 `MOVIE_INELIGIBLE`;404 missing movie;503 upstream. Adding never replaces existing offered/accepted pick. If current pointer is no_match, clear it and increment session version to expose expanded eligibility.

### DELETE `/watchlist/{entry_id}`

Archive owned entry,200 `{removed:true,today:TodayEnvelope}` (`today` present from P4; ADR 004). Already removed succeeds.404 wrong owner/nonexistent. Supersede and clear current choice when it matches; do not generate replacement. Cached no-match also clears when candidate inventory changes.

## Today and context

### GET `/today`

Read current local-date envelope;200. Does not create session, select movie, record an offer or call LLM. Errors auth/DB only.

### PATCH `/today/context`

Complete replacement, not a partial merge:

```json
{
  "expected_session_version": 2,
  "context": {
    "max_runtime_minutes": 90,
    "pace": null,
    "complexity_max": 0.45,
    "heaviness_max": 0.35,
    "prefer_genre_ids": [],
    "avoid_genre_ids": [],
    "current_mood": null,
    "desired_experience": "relax"
  }
}
```

200 TodayEnvelope; creates session if absent/version0. Changed effective scoring context supersedes an offered/accepted result and clears pointer; an old no_match row stays terminal unchanged. Increment version. Identical complete context is a no-op with same version. Emotion-only edits update version/context but preserve the current pick; compare effective desired experience/time/genre/advanced fields when deciding invalidation. Existing completed session ->409 `TODAY_COMPLETED`. It does not choose another.422 validation,409 conflict. Raw text/proposal IDs are not required and not persisted.

### POST `/today/choose`

Initial primary flow request:

```json
{
  "expected_session_version": 0,
  "context": {
    "current_mood": "down",
    "desired_experience": "comfort",
    "max_runtime_minutes": 100,
    "pace": null,
    "complexity_max": null,
    "heaviness_max": null,
    "prefer_genre_ids": [],
    "avoid_genre_ids": []
  },
  "continue_after_pause": false
}
```

Context is optional only for an existing session with confirmed intent. Missing initial context or null desired_experience ->422 CONTEXT_REQUIRED. Supplied complete context is atomically applied; changed effective scoring fields select ONE film; accepted-pick replacement requires user-facing confirmation. Unchanged effective scoring fields/current offered/accepted pick ->200 same film; an emotion-only metadata edit may increment session version without a selection attempt. New attempt ->201 TodayEnvelope; no_match also201. Return only one movie, never top_candidates. No-match explicit retry has a new key/count; no client auto retry.

After >=3 rejections and no current pick, unchanged context requires continue_after_pause=true for a deliberate Continue once. Otherwise409 CONTEXT_REVIEW_REQUIRED; the UI shows Adjust context/Continue once. Compare effective scoring fields with the last selection attempt (excluding current_mood): a genuine change plus Pick with this context allows one attempt without resetting rejection_count. This also works after a separate Save of new scoring context; emotion-only or profile-overridden no-effect edits do not bypass pause.20 attempts/day ->429; completed409; stale version409. Repeated GET/transport key replay never count or choose again.

### POST `/context/parse`

Request `{text:"I’m exhausted but want something exciting and under 2 hours."}`. No idempotency key; does not mutate. Require AI opt-in for provider calls; deterministic parser/structured fallback may still respond when disabled.200:

```json
{
  "proposal": {
    "max_runtime_minutes": 119,
    "pace": null,
    "complexity_max": null,
    "heaviness_max": null,
    "prefer_genre_ids": [],
    "avoid_genre_ids": [],
    "current_mood": "tired",
    "desired_experience": "exciting"
  },
  "source": "ollama",
  "field_sources": {
    "max_runtime_minutes": "deterministic_time_parser",
    "current_mood": "llm",
    "desired_experience": "llm"
  },
  "warnings": [],
  "requires_review": true,
  "needs_desired_experience": false,
  "follow_up_choices": []
}
```

If current_mood=down and desired_experience is absent, return needs_desired_experience=true and follow_up_choices:[{label:"Cheer me up",value:"make_me_laugh"},{label:"Something comforting",value:"comfort"},{label:"Let me feel it",value:"feel_it"},{label:"Surprise me",value:"surprise"}], with desired_experience=null. Other moods/no inferred mood with missing intent use the full eight supported intent choices. Never automatically fill comedy. The same follow-up requirement applies when fallback cannot infer intent. Provider errors/invalid outputs normally return200 with `source:"structured_fallback"`, deterministic explicit time only, and warning `AI_UNAVAILABLE` or `AI_OUTPUT_REJECTED`; no invented inferred fields. Ambiguous/conflicting time ->null cap plus `TIME_NEEDS_REVIEW`. If extraction is valid but cap conflicts with profile, warn profile cap still applies.422 input too long;429 parse limit;503 infrastructure failure unrelated to optional AI.

Deterministic time parser supports digits/English number words for minutes/hours, “under”, “at most”, “or less”, “only have”, and “about”. Explicit supported “under 2 hours” must not be weakened to120 by LLM. Unrecognized numbers or conflicting intervals warn; user edits. V1 is English context input only; unsupported language returns a warning and structured controls. Negation/mood semantics are reviewed via proposal, not asserted certain.

Canonical proposal rules: sad/down ->current_mood=down only, tired/exhausted ->current_mood=tired only; neither implies intent or movie traits. Explicit “cheer me up/make me laugh” ->make_me_laugh; “comforting” ->comfort; “let me feel it” ->feel_it; “relaxing/lighter” ->relax; “deep” ->deep; “exciting” ->exciting; “keep me hooked” ->keep_me_hooked; “surprise me” ->surprise. Explicit “fast-paced” ->pace=high, “slow/calm pacing” ->pace=low, “easy/simple viewing” ->complexity_max=.45, and “avoid heavy/serious” ->heaviness_max=.35. Negated terms do not trigger positive mappings. Unsupported descriptions stay in warnings, not invented fields. Other explicit numeric soft limits may be proposed only inside schema ranges. Numeric hard time detected deterministically takes precedence over any model value. All inferred semantics still require user review; temperature zero does not guarantee identical provider outputs.

## Recommendation actions and history

### POST `/recommendations/{id}/accept`

Request `{expected_session_version:2}`;200 TodayEnvelope with accepted state. Only current offered recommendation in today's session. Accepted same resource is semantic no-op if version current.409 stale/not-current/expired/completed. Does not learn or watch. No network provider work.

### POST `/recommendations/{id}/reject`

Request examples:

```json
{
  "expected_session_version": 3,
  "reason": "too_long",
  "details": {
    "max_runtime_minutes": 90
  },
  "note": null,
  "choose_another": true
}
```

```json
{
  "expected_session_version": 3,
  "reason": "wrong_genre",
  "details": {
    "avoid_genre_ids": [
      18
    ]
  },
  "note": null,
  "choose_another": true
}
```

P5 accepts not_tonight/too_long/wrong_genre/too_serious/want_lighter/other, already_watched (records a viewing with unknown or past date, no rating, never tonight's completion; ADR 006 amendment) and never_recommend (persistent user-scoped block). Request also accepts choose_another boolean, defaultfalse, alongside expected_session_version/reason/details/note. UI Pick another and direct Already seen send true; Stop sends false. Just give me another and Not feeling this one both map to not_tonight, never implicit dislike. Reason code enum in PROJECT_SPEC. Details defaults `{}`. For wrong_genre require nonempty chosen subset of selected film genres. For too_long optional cap must be shorter than effective existing cap if present; if absent any valid user-entered cap is accepted. All other reason-specific extra detail keys rejected. Already_watched may include `watched_at:null|past timestamp`; never_recommend has no detail. Other may have optional note. Only current offered/accepted resource in today's session.

200 `{feedback:{id:"uuid",reason:"too_long",created_at:"..."},viewing:null|ViewingSummary,today:TodayEnvelope}`. Atomic rejection/context/watch/block changes. Old pointer cleared, session version incremented ONCE for the whole atomic command. With choose_another=true, select exactly ONE replacement atomically under updated context (no_match allowed), and return that as today.recommendation. On third/later rejection or exhausted durable attempt quota, feedback still commits but no auto-replacement; return paused or ready with replacement_outcome=paused|daily_limit and no film. Defaultfalse selects none. Add replacement_outcome=selected|no_match|paused|daily_limit|not_requested to the response. No partial feedback failure is hidden: invalid requests roll back; no-match/pause/quota outcomes are valid committed feedback results. Wrong-genre effects remove avoided IDs from tonight's preferred list. Want-lighter sets desired_experience=relax and optional heaviness target; too-serious sets only heaviness target, as specified, preserving all unrelated context fields.409 invalid transition/version;422 unsupported detail.

### POST `/recommendations/{id}/watched`

Request `{expected_session_version:3,rating:4}`; rating is optional or null, otherwise a strict whole integer from 1 through 5.200 `{viewing:ViewingSummary,today:TodayEnvelope}`. Current offered or accepted today; allow offered because user may have watched without tapping accept. Records server completion time, archives watchlist, marks record watched and session completed atomically. `today.viewing` is also populated for the completed card.409 stale/noncurrent/expired. Rating may be skipped and edited later. Retries cannot create second viewing.

### POST `/recommendations/{id}/follow-up`

Request `{action:"yes"|"no"|"not_yet"}`; the recommendation must belong to this user and an earlier local date. `yes` records through the canonical viewing path and resolves the accepted intent; `no` resolves it without a viewing and leaves inventory alone; `not_yet` stores the user's local date and can be asked again only on a later local date. Response200 TodayEnvelope; same-key retries replay. GET `/today` returns at most the most recent unresolved accepted recommendation, including after missed days. No action duplicates a viewing.

### GET `/recommendations`

Owned paginated history, created_at DESC,id DESC;optional `status` enum filter.200 list RecommendationSummary plus session local_date/timezone per item. Empty valid. Includes no_match/superseded rows. Never another user's candidate data.

### GET `/recommendations/{id}`

200 `{recommendation:RecommendationSummary,context:SessionContext,effective_context:SessionContext,feedback:null|{reason,details,note,created_at},breakdown:{components:{G:0.65,C:0.916667,D:0.75,A:0.333333,R:1,Q:0.65},weights:{G:35,C:30,D:10,A:10,R:10,Q:5},contributions:{G:22.75,C:27.5,D:7.5,A:3.333333,R:10,Q:3.25}}}`. No-match breakdown null. Uses stored snapshot, not current global metadata.404 wrong owner.

### GET `/recommendations/{id}/comparison`

Owned secondary engineering/debug view;200 `{engine_version,config_version,config_hash,evaluated_at,winner:{movie,rank:1,total_score,components,contributions,scoring_inputs},top_candidates:[{movie,rank,total_score,components,contributions,scoring_inputs}],exclusion_summary:{candidate_count,eligible_count,primary_exclusion_counts},comparisons_truncated:false}`. At most nine runners-up, ten films total; no individual excluded records or discarded-candidate inputs. no_match winner=null/top_candidates=[] with aggregate counts.404 wrong owner.

Do not include this array in TodayEnvelope or main history list. No actions to choose a runner-up in Tonight. Developer inspection can show stored score comparisons, not reconstruct the entire historical candidate set. Complete replay tests use full test fixtures; no full-production audit or replay endpoint. Bound evidence to64KiB as DATA_MODEL defines.

## Watched records and ratings

### GET `/viewings`

200 paginated ViewingSummary, COALESCE(watched_at,recorded_at) DESC,id DESC:

```json
{
  "items": [
    {
      "id": "uuid",
      "movie": {
        "tmdb_id": 104,
        "title": "Run Lola Run",
        "year": 1998,
        "runtime_minutes": 81,
        "genre_ids": [
          28,
          18,
          53
        ],
        "genres": [
          {
            "id": 28,
            "name": "Action"
          },
          {
            "id": 18,
            "name": "Drama"
          },
          {
            "id": 53,
            "name": "Thriller"
          }
        ],
        "poster_url": null,
        "can_add": true
      },
      "watched_at": null,
      "recorded_at": "2026-10-01T22:30:00Z",
      "source": "already_watched",
      "rating": null,
      "version": 1,
      "recommendation_id": null
    }
  ],
  "next_cursor": null
}
```

### POST `/viewings`

Log known watched film from search/details, even outside watchlist. Request `{tmdb_id:104,watched_at:null,rating:5}`. Rating is null or a strict whole integer 1–5; absent and unrated remain null. Nullable date means unknown; future date422.201 `{viewing:ViewingSummary,already_recorded:false,today:TodayEnvelope}`. Existing record returns200 `already_recorded:true`, preserving old rating/date; use explicit PATCH to edit rating. Archive watchlist atomically. If movie is current offered/accepted choice, supersede it and clear pointer because it is now ineligible; do not complete Today. Manual history entry, including a supplied date today, is not the recommendation's Mark watched action. Completed sessions stay complete with their existing card.404/503 metadata;422 ineligible/future date.

### PATCH `/viewings/{id}`

Request `{expected_version:1,rating:1}`; null clears rating.200 ViewingSummary with incremented version if changed. No watch-date edit/delete/rewatch in V1.409 version;404 ownership. Learning uses replacement value exactly once. Does not replace today's current choice. Migration 0006 maps legacy Disliked→1, Okay→3, Liked→4, Loved→5; null stays null.

## Health

GET `/healthz` ->200 `{status:"ok"}`; public, no secrets. GET `/readyz` ->200 `{status:"ready"}` or503 `{status:"not_ready"}` after DB/migration check. Phase0 only implements healthz; readiness arrives with persistence. Provider outages do not make app unready when cached ranking can work.

## Contract verification matrix

Test successful flow, every documented transition conflict, 2-account ownership, duplicate key replay/hash mismatch, stale preference/session/viewing versions, no-match201, acceptance without history, permanent block without genre-learning, already-watched date uncertainty, parse that mutates nothing, and lookup/page errors. Flutter repositories must consume these contracts rather than inventing endpoint names or client-side score fields.

## One-choice presentation contract

TodayEnvelope carries exactly one recommendation/movie or null; no candidates/top_candidates/alternatives arrays. desired_experience, current_mood and time are returned separately in session context. Complete ranking remains internal. GET comparison is not a feed and is never used to place alternate cards beside the selected film. Replacement counts and pause behavior are server authoritative. Test full context-first flow, emotion-only clarification, single replacement, third-rejection pause, explicit continuation and no taste learning from skip reasons.
