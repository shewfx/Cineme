# Critical review before implementation

The concept is strong enough for a portfolio. The risk is promising sophistication the data cannot support and then disguising that gap with generated prose. The engineering value is in correct feedback semantics, measurable ranking and reliable state, not the number of AI features. The defining UX is lightweight context -> ONE movie, not a smaller Netflix recommendation grid. Sad users choose Cheer me up, Comfort, Let me feel it or Surprise me; the app must not assume comedy.

## 1. Subjective metadata is the biggest missing dependency

TMDB provides factual movie metadata. Its movie detail contract is not a reliable source of standardized complexity, pace, emotional heaviness or “easy viewing” ratings. Genre cannot safely substitute for these traits: comedy can be bleak, action can be complicated, animation can be emotionally heavy.

**Decision:** Pace/complexity/heaviness are optional reviewed enrichment, never a core prerequisite. V1 must run with no dataset/rows. Unknown is explicit and neutral, with no weight redistribution. Desired-experience matching uses a labeled genre heuristic; current emotion does not choose a genre.

**Why:** Runtime/genre and explicit preferences/history can support a useful deterministic baseline. Optional enrichment makes a stronger limited demo without pretending to cover every film.

**Tradeoff:** Context matching is more specific for reviewed films; the remaining films get neutral unknown trait values. Put trait controls in Advanced and disclose uncertainty. Never market genre-based comfort as guaranteed or claim good outcomes without user evaluation.

## 2. Watchlist intent is not proof of liking

Saving a movie means interest in watching it, not positive experience. Repeatedly declining a film on tired evenings does not prove dislike either.

**Decision:** Watchlist determines eligibility. Explicit genre preferences and post-watch ratings determine long-term taste. Tonight-only feedback changes the current session. “Never recommend” is an explicit reversible movie block.

**Tradeoff:** Less aggressive learning, but substantially fewer false inferences. The watchlist's genre distribution is deliberately not treated as a learned preference in V1.

## 3. Private JustWatch access must not be the foundation

Official JustWatch materials describe partner availability/catalogue integrations. They do not establish an available consumer private-watchlist OAuth integration for Cinemé. This is not a proof that no such arrangement could ever exist.

**Decision:** Internal watchlist plus backend TMDB search/add. Source-neutral ingestion commands accept normalized movie identities. No JustWatch login, scraped cookies, reverse-engineered private endpoints or promised live sync.

**Tradeoff:** Users add movies themselves initially. A user-supplied CSV importer is a credible first extension; it is outside V1.

## 4. “One movie” needs state, not just a sorting function

Re-ranking on every screen load makes the app feel arbitrary. Duplicate taps can record duplicate watches. Context edits can race with rejections.

**Decision:** One persisted session per user and local calendar date, versioned mutations, idempotency keys, locked per-user writes and bounded winner/comparison evidence. GET requests do not generate picks. Rank all candidates in memory, persist only winner plus at most nine runners-up, config/context and aggregate exclusions. Full replay fixtures belong in tests, not production DB.

**Tradeoff:** A few relational tables and explicit transitions. This complexity earns its place because it protects the core product promise.

## 5. “Watch Tonight” is intention, not completion

**Decision:** Accepting a recommendation pins it. Only “Mark watched” creates viewing history. No automatic watched state at midnight, no positive taste update from acceptance, no streaming playback integration.

**Tradeoff:** One extra completion action, but clean learning signals.

## 6. No match is a valid answer

**Decision:** Never silently exceed a runtime cap, resurrect a blocked movie or recommend outside the watchlist. Explain which constraints excluded movies and offer explicit edits. Unknown runtime fails a runtime cap.

**Tradeoff:** Some requests return no movie. That is more useful than claiming a 130-minute movie fits a 90-minute evening.

## 7. Keep AI at the interpretation boundary

**Decision:** Optional local LLM proposes context; the user sees and applies structured fields. A deterministic parser extracts explicit time boundaries first. LLM output cannot loosen them. V1 explanations use templates from saved reasons; emotional state and desired viewing effect are distinct; generative explanation wording is deferred.

**Why:** Free-form explanations can hallucinate content, acting credits, streaming availability or certainty about unknown traits. The project still demonstrates real structured LLM integration without surrendering the decision.

**Tradeoff:** Less literary copy, substantially stronger evidence. Provider abstraction supports later adapters without pretending every “OpenAI-compatible” endpoint has identical structured-output support.

## 8. Build identity before private-data features

**Decision:** Supabase Auth handles email/password, verification and recovery. FastAPI uses a thin library-backed verifier and owns all app authorization. POST me/bootstrap explicitly initializes two identity tables; GET me is read-only. Build the fake UI at P1, then minimal auth/persistence at P2 in small submilestones. PostgreSQL remains accessed through FastAPI, including when hosted by Supabase.

**Why:** Two students should spend their effort on ranking and product behavior, not maintaining a password and refresh-token service. Authentication remains demonstrable through secure integration, token verification and isolation tests.

**Tradeoff:** Hosted identity dependency in normal development. Offline test auth exists only through test dependency overrides, never a production bypass.

## 9. Resist catalogue and infrastructure expansion

**Decision:** Android is the required client. Four main tabs; Search/Add is a nested route. Modular monolith, on-demand ranking over at most 500 active watchlist movies, no nightly scheduler, queue, vector store, Redis or microservices.

**Tradeoff:** No daily push, automatic imports, playback or subscription comparison. A functioning narrow product beats eleven half-working subsystems.

## 10. Personalization claims must be measurable

**Decision:** Genre-level content-based learning with shrinkage and explicit ratings. Report small sample counts. Measure rejection reasons and choice acceptance; do not assert “accuracy improved” without evaluation.

**Tradeoff:** It will not learn nuanced director/style preferences in V1. That is an honest limit, not a reason to bolt on a neural recommender.

## Practical execution

Nine gated phases are defined in DEVELOPMENT_PLAN. Two students can divide frontend and backend, but must jointly review API and scorer changes. Do not estimate completion from generated line counts. Track accepted behaviors, passing tests and reproducible manual demos.
