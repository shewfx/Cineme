import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../features/history/data/history_repository.dart';
import '../features/preferences/data/profile_repository.dart';
import '../features/search/data/search_repository.dart';
import '../features/today/data/today_repository.dart';
import '../features/watchlist/data/watchlist_repository.dart';
import '../shared/models/inventory.dart';
import '../shared/models/movie.dart';
import '../shared/models/profile.dart';
import '../shared/models/session_context.dart';
import '../shared/models/today_state.dart';
import '../shared/models/viewing.dart';
import 'preview_catalog.dart';

/// Thrown by every fake while "Simulate connection errors" is on.
class PreviewConnectionError implements Exception {
  const PreviewConnectionError();

  @override
  String toString() => 'Preview: simulated connection error';
}

const pauseAfterRejections = 3;

/// In-memory stand-in for the server in the UI-preview build only, holding
/// one daily session. It follows the documented lifecycle: Tonight picks only
/// from the active watchlist and never re-offers a film offered this session;
/// accept is intention, Mark watched completes the day, ratings are separate;
/// rejections are scoped to tonight and the third one pauses replacement;
/// removing, blocking or logging the current pick clears it without choosing.
class PreviewStore {
  PreviewStore({
    List<Movie> watchlist = previewWatchlist,
    bool seedHistory = true,
    this.latency = const Duration(milliseconds: 450),
    DateTime Function()? now,
  }) : now = now ?? DateTime.now {
    final start = this.now();
    for (final m in [...watchlist, ...previewSearchOnly, previewUnreleased]) {
      _catalog[m.tmdbId] = m;
    }
    for (var i = 0; i < watchlist.length; i++) {
      _active.add(
        WatchlistEntry(
          id: _id('w'),
          movie: watchlist[i],
          addedAt: start.subtract(Duration(days: i + 1)),
        ),
      );
    }
    if (seedHistory) {
      final amelie = _catalog[194]!;
      _viewings
        ..add(
          Viewing(
            id: _id('v'),
            movie: amelie,
            watchedAt: start.subtract(const Duration(days: 12)),
            recordedAt: start.subtract(const Duration(days: 12)),
            rating: Rating.liked,
          ),
        )
        ..add(
          Viewing(
            id: _id('v'),
            movie: _catalog[129]!,
            watchedAt: null,
            recordedAt: start.subtract(const Duration(days: 30)),
            rating: null,
          ),
        );
      _records.add(
        RecommendationRecord(
          id: _id('r'),
          movie: amelie,
          status: RecommendationStatus.watched,
          createdAt: start.subtract(const Duration(days: 12, hours: 2)),
          desiredExperience: DesiredExperience.comfort,
        ),
      );
    }
  }

  final Duration latency;
  final DateTime Function() now;

  /// Preview-only switch exposed in Profile so error states can be shown.
  bool simulateErrors = false;

  final _catalog = <int, Movie>{};
  final _active = <WatchlistEntry>[]; // newest first
  final _viewings = <Viewing>[]; // newest first
  final _records = <RecommendationRecord>[]; // newest first
  final _blocked = <int>{};
  int _seq = 0;

  // Today's session.
  SessionContext? _context;
  SessionContext? _lastAttempt;
  Recommendation? _current; // offered or accepted
  NoMatchSummary? _noMatch;
  Recommendation? _completed;
  String? _completedViewingId;
  final _offeredToday = <int>{};
  int _rejections = 0;

  String _id(String prefix) => 'preview-$prefix${++_seq}';

  Future<void> _io() async {
    await Future<void>.delayed(latency);
    if (simulateErrors) throw const PreviewConnectionError();
  }

  /// Offset cursor; the real API's cursor is opaque.
  Paged<T> _page<T>(List<T> all, String? cursor, int size) {
    final start = int.tryParse(cursor ?? '') ?? 0;
    final end = (start + size).clamp(0, all.length);
    return Paged(
      all.sublist(start.clamp(0, all.length), end),
      end < all.length ? '$end' : null,
    );
  }

  bool _watched(int tmdbId) => _viewings.any((v) => v.movie.tmdbId == tmdbId);

  void _setRecord(
    String id,
    RecommendationStatus status, {
    String? reasonLabel,
  }) {
    final i = _records.indexWhere((r) => r.id == id);
    if (i >= 0) {
      _records[i] = _records[i].withStatus(status, reasonLabel: reasonLabel);
    }
  }

  /// Clears the current pick without choosing another (removal, block,
  /// manual watched, changed scoring context).
  void _supersedeCurrent() {
    final current = _current;
    if (current == null) return;
    _setRecord(current.id, RecommendationStatus.superseded);
    _current = null;
  }

  /// Leaves the eligible inventory; a cached no-match no longer applies.
  void _archive(int tmdbId, {bool supersede = true}) {
    _active.removeWhere((e) => e.movie.tmdbId == tmdbId);
    _noMatch = null;
    if (supersede && _current?.movie.tmdbId == tmdbId) _supersedeCurrent();
  }

  /// API_CONTRACT state precedence.
  TodayEnvelope _envelope() {
    if (_completed != null) {
      return TodayEnvelope(
        state: TodayStatus.completed,
        context: _context,
        recommendation: _completed,
        viewing: _viewings.firstWhere((v) => v.id == _completedViewingId),
        rejectionCount: _rejections,
      );
    }
    final current = _current;
    if (current != null) {
      return TodayEnvelope(
        state: current.status == RecommendationStatus.accepted
            ? TodayStatus.accepted
            : TodayStatus.offered,
        context: _context,
        recommendation: current,
        rejectionCount: _rejections,
      );
    }
    final TodayStatus state;
    if (_noMatch != null) {
      state = TodayStatus.noMatch;
    } else if (_active.isEmpty) {
      state = TodayStatus.emptyWatchlist;
    } else if (_context == null) {
      state = TodayStatus.notStarted;
    } else if (_rejections >= pauseAfterRejections) {
      state = TodayStatus.paused;
    } else {
      state = TodayStatus.ready;
    }
    return TodayEnvelope(
      state: state,
      context: _context,
      noMatch: _noMatch,
      rejectionCount: _rejections,
    );
  }

  /// One selection attempt. Scripted, not ranked: hard exclusions in the
  /// engine's precedence, then the intent's scripted films, then the rest of
  /// the eligible watchlist in order. No fallback outside the watchlist and
  /// no relaxing of limits: if nothing qualifies, the result is no match.
  void _select(SessionContext ctx) {
    _lastAttempt = ctx;
    final cap = ctx.maxRuntimeMinutes;
    final counts = <ExclusionCode, int>{};
    final eligible = <Movie>[];
    for (final e in _active) {
      final m = e.movie;
      final code = _blocked.contains(m.tmdbId)
          ? ExclusionCode.movieBlocked
          : _offeredToday.contains(m.tmdbId)
          ? ExclusionCode.offeredThisSession
          : m.genres.any((g) => ctx.avoidGenreIds.contains(g.id))
          ? ExclusionCode.genreBlocked
          : cap != null && m.runtimeMinutes == null
          ? ExclusionCode.runtimeUnknown
          : cap != null && m.runtimeMinutes! > cap
          ? ExclusionCode.runtimeExceeded
          : null;
      if (code == null) {
        eligible.add(m);
      } else {
        counts[code] = (counts[code] ?? 0) + 1;
      }
    }

    if (eligible.isEmpty) {
      _noMatch = NoMatchSummary(candidateCount: _active.length, counts: counts);
      _records.insert(
        0,
        RecommendationRecord(
          id: _id('r'),
          movie: null,
          status: RecommendationStatus.noMatch,
          createdAt: now(),
          desiredExperience: ctx.desiredExperience,
        ),
      );
      return;
    }

    final script = previewScript[ctx.desiredExperience]!;
    eligible.sort((a, b) {
      int rank(Movie m) {
        final i = script.indexOf(m.tmdbId);
        return i < 0 ? script.length : i;
      }

      return rank(a).compareTo(rank(b)); // stable: watchlist order otherwise
    });
    final movie = eligible.first;
    final intentGenres = previewIntentGenres[ctx.desiredExperience]!;
    final matched = movie.genres.where((g) => intentGenres.contains(g.id));
    final recommendation = Recommendation(
      id: _id('r'),
      movie: movie,
      reasons: [
        if (ctx.desiredExperience == DesiredExperience.surprise)
          const SurpriseChosen()
        else if (matched.isNotEmpty)
          GenreMatchesIntent(
            genre: matched.first,
            intent: ctx.desiredExperience,
          )
        else
          WeakIntentMatch(ctx.desiredExperience),
        if (cap != null)
          FitsRuntime(runtimeMinutes: movie.runtimeMinutes!, capMinutes: cap),
      ],
    );
    _offeredToday.add(movie.tmdbId);
    _current = recommendation;
    _records.insert(
      0,
      RecommendationRecord(
        id: recommendation.id,
        movie: movie,
        status: RecommendationStatus.offered,
        createdAt: now(),
        desiredExperience: ctx.desiredExperience,
      ),
    );
  }

  Viewing _recordViewing(Movie movie, {DateTime? watchedAt, Rating? rating}) {
    final viewing = Viewing(
      id: _id('v'),
      movie: movie,
      watchedAt: watchedAt,
      recordedAt: now(),
      rating: rating,
    );
    _viewings.insert(0, viewing);
    return viewing;
  }
}

const _reasonLabels = {
  RejectReason.notTonight: 'Not tonight',
  RejectReason.tooLong: 'Too long',
  RejectReason.wantLighter: 'Something lighter',
  RejectReason.wrongGenre: 'Different genre',
  RejectReason.alreadyWatched: 'Already seen',
  RejectReason.neverRecommend: 'Never recommend',
};

class FakeTodayRepository implements TodayRepository {
  FakeTodayRepository(this._s);

  final PreviewStore _s;

  void _notCompleted() {
    if (_s._completed != null) throw const TodayConflict('TODAY_COMPLETED');
  }

  @override
  Future<TodayEnvelope> today() async {
    await _s._io();
    return _s._envelope();
  }

  @override
  Future<TodayEnvelope> choose(
    SessionContext context, {
    bool continueAfterPause = false,
  }) async {
    await _s._io();
    _notCompleted();
    final current = _s._current;
    if (current != null) {
      // Same scoring context: same film; a mood-only change is metadata.
      if (_s._context!.sameScoringAs(context)) {
        _s._context = context;
        return _s._envelope();
      }
      _s._supersedeCurrent();
    }
    if (_s._active.isEmpty) {
      _s._context = context;
      return _s._envelope();
    }
    final last = _s._lastAttempt;
    if (_s._rejections >= pauseAfterRejections &&
        !continueAfterPause &&
        last != null &&
        last.sameScoringAs(context)) {
      throw const TodayConflict('CONTEXT_REVIEW_REQUIRED');
    }
    _s
      .._context = context
      .._noMatch = null
      .._select(context);
    return _s._envelope();
  }

  @override
  Future<TodayEnvelope> saveContext(SessionContext context) async {
    await _s._io();
    _notCompleted();
    final saved = _s._context;
    final changed = saved == null || !saved.sameScoringAs(context);
    _s._context = context;
    if (changed) {
      _s
        .._supersedeCurrent()
        .._noMatch = null; // the old no-match row stays in history
    }
    return _s._envelope();
  }

  @override
  Future<TodayEnvelope> accept(String recommendationId) async {
    await _s._io();
    final current = _s._current;
    if (current == null || current.id != recommendationId) {
      throw const TodayConflict('INVALID_TRANSITION');
    }
    if (current.status == RecommendationStatus.offered) {
      _s._current = current.withStatus(RecommendationStatus.accepted);
      _s._setRecord(current.id, RecommendationStatus.accepted);
    }
    return _s._envelope();
  }

  @override
  Future<RejectResult> reject(
    String recommendationId,
    RejectReason reason, {
    int? maxRuntimeMinutes,
    Set<int> avoidGenreIds = const {},
    required bool chooseAnother,
  }) async {
    await _s._io();
    final current = _s._current;
    if (current == null || current.id != recommendationId) {
      throw const TodayConflict('INVALID_TRANSITION');
    }
    var ctx = _s._context!;
    // Validate everything first so an invalid request changes nothing.
    switch (reason) {
      case RejectReason.tooLong when maxRuntimeMinutes != null:
        final existing = ctx.maxRuntimeMinutes;
        if (maxRuntimeMinutes < 1 ||
            (existing != null && maxRuntimeMinutes >= existing)) {
          throw const TodayConflict('VALIDATION_ERROR');
        }
        ctx = ctx.copyWith(maxRuntimeMinutes: () => maxRuntimeMinutes);
      case RejectReason.wrongGenre:
        final filmGenres = current.movie.genres.map((g) => g.id).toSet();
        if (avoidGenreIds.isEmpty || !filmGenres.containsAll(avoidGenreIds)) {
          throw const TodayConflict('VALIDATION_ERROR');
        }
        ctx = ctx.copyWith(
          avoidGenreIds: {...ctx.avoidGenreIds, ...avoidGenreIds},
        );
      case RejectReason.wantLighter:
        ctx = ctx.copyWith(
          desiredExperience: DesiredExperience.relax,
          heavinessMax: () => 0.35,
        );
      default:
    }

    final movie = current.movie;
    if (reason == RejectReason.alreadyWatched) {
      if (!_s._watched(movie.tmdbId)) _s._recordViewing(movie);
      _s._archive(movie.tmdbId, supersede: false);
    } else if (reason == RejectReason.neverRecommend) {
      _s._blocked.add(movie.tmdbId);
      _s._archive(movie.tmdbId, supersede: false);
    }
    _s
      .._context = ctx
      .._setRecord(
        current.id,
        RecommendationStatus.rejected,
        reasonLabel: _reasonLabels[reason],
      )
      .._current = null
      .._rejections += 1;

    final ReplacementOutcome outcome;
    if (!chooseAnother) {
      outcome = ReplacementOutcome.notRequested;
    } else if (_s._rejections >= pauseAfterRejections) {
      outcome = ReplacementOutcome.paused;
    } else {
      _s._select(ctx);
      outcome = _s._current != null
          ? ReplacementOutcome.selected
          : ReplacementOutcome.noMatch;
    }
    return RejectResult(outcome: outcome, today: _s._envelope());
  }

  @override
  Future<TodayEnvelope> markWatched(
    String recommendationId, {
    Rating? rating,
  }) async {
    await _s._io();
    final current = _s._current;
    if (current == null || current.id != recommendationId) {
      throw const TodayConflict('INVALID_TRANSITION');
    }
    final viewing = _s._recordViewing(
      current.movie,
      watchedAt: _s.now(),
      rating: rating,
    );
    _s
      .._archive(current.movie.tmdbId, supersede: false)
      .._setRecord(current.id, RecommendationStatus.watched)
      .._completed = current.withStatus(RecommendationStatus.watched)
      .._completedViewingId = viewing.id
      .._current = null;
    return _s._envelope();
  }
}

class FakeWatchlistRepository implements WatchlistRepository {
  FakeWatchlistRepository(this._s);

  final PreviewStore _s;

  @override
  Future<Paged<WatchlistEntry>> list({String? cursor}) async {
    await _s._io();
    return _s._page(_s._active, cursor, pageSize);
  }

  @override
  Future<WatchlistAddResult> add(int tmdbId) async {
    await _s._io();
    final movie = _s._catalog[tmdbId];
    if (movie == null) throw const InventoryConflict('NOT_FOUND');
    if (identical(movie, previewUnreleased)) {
      throw const InventoryConflict('MOVIE_INELIGIBLE');
    }
    if (_s._watched(tmdbId)) {
      throw const InventoryConflict('MOVIE_ALREADY_WATCHED');
    }
    if (_s._blocked.contains(tmdbId)) {
      throw const InventoryConflict('MOVIE_BLOCKED');
    }
    for (final e in _s._active) {
      if (e.movie.tmdbId == tmdbId) {
        return WatchlistAddResult(entry: e, alreadyPresent: true);
      }
    }
    // A restored entry gets a fresh added_at, like a new one. Adding never
    // replaces the current pick, but a cached no-match no longer applies.
    final entry = WatchlistEntry(
      id: _s._id('w'),
      movie: movie,
      addedAt: _s.now(),
    );
    _s._active.insert(0, entry);
    _s._noMatch = null;
    return WatchlistAddResult(entry: entry, alreadyPresent: false);
  }

  @override
  Future<void> remove(String entryId) async {
    await _s._io();
    final i = _s._active.indexWhere((e) => e.id == entryId);
    if (i >= 0) _s._archive(_s._active[i].movie.tmdbId);
  }
}

class FakeSearchRepository implements MovieSearchRepository {
  FakeSearchRepository(this._s, {this.resultsPerPage = 6});

  final PreviewStore _s;
  final int resultsPerPage;

  @override
  Future<SearchPage> search(String query, {int page = 1}) async {
    await _s._io();
    final q = query.trim().toLowerCase();
    final matches = [
      for (final m in _s._catalog.values)
        if (m.title.toLowerCase().contains(q)) m,
    ]..sort((a, b) => a.title.compareTo(b.title));
    final known = {
      for (final e in _s._active) e.movie.tmdbId,
      for (final v in _s._viewings) v.movie.tmdbId,
    };
    final totalPages = (matches.length / resultsPerPage).ceil();
    final slice = matches
        .skip((page - 1) * resultsPerPage)
        .take(resultsPerPage);
    return SearchPage(
      page: page,
      totalPages: totalPages,
      results: [
        for (final m in slice)
          SearchResult(
            // Search does not know runtime unless details are cached.
            movie: known.contains(m.tmdbId)
                ? m
                : Movie(
                    tmdbId: m.tmdbId,
                    title: m.title,
                    year: m.year,
                    runtimeMinutes: null,
                    genres: m.genres,
                  ),
            canAdd: !identical(m, previewUnreleased),
          ),
      ],
    );
  }
}

class FakeHistoryRepository implements HistoryRepository {
  FakeHistoryRepository(this._s);

  final PreviewStore _s;

  @override
  Future<Paged<Viewing>> viewings({String? cursor}) async {
    await _s._io();
    return _s._page(_s._viewings, cursor, pageSize);
  }

  @override
  Future<Paged<RecommendationRecord>> recommendations({String? cursor}) async {
    await _s._io();
    return _s._page(_s._records, cursor, pageSize);
  }

  @override
  Future<RecordWatchedResult> recordAlreadyWatched(int tmdbId) async {
    await _s._io();
    for (final v in _s._viewings) {
      if (v.movie.tmdbId == tmdbId) {
        return RecordWatchedResult(viewing: v, alreadyRecorded: true);
      }
    }
    final movie = _s._catalog[tmdbId];
    if (movie == null) throw const InventoryConflict('NOT_FOUND');
    if (identical(movie, previewUnreleased)) {
      throw const InventoryConflict('MOVIE_INELIGIBLE');
    }
    final viewing = _s._recordViewing(movie);
    // Archives the entry; if it was tonight's pick, clears it. Never
    // completes Tonight.
    _s._archive(tmdbId);
    return RecordWatchedResult(viewing: viewing, alreadyRecorded: false);
  }

  @override
  Future<Viewing> rateViewing(String viewingId, Rating? rating) async {
    await _s._io();
    final i = _s._viewings.indexWhere((v) => v.id == viewingId);
    if (i < 0) throw const InventoryConflict('NOT_FOUND');
    final v = _s._viewings[i];
    // Replaces the single observation; never adds a second one.
    return _s._viewings[i] = Viewing(
      id: v.id,
      movie: v.movie,
      watchedAt: v.watchedAt,
      recordedAt: v.recordedAt,
      rating: rating,
    );
  }
}

class FakeProfileRepository implements ProfileRepository {
  FakeProfileRepository(this._s);

  final PreviewStore _s;

  @override
  Future<Profile> profile() async {
    await _s._io();
    return Profile(
      displayName: null,
      timezone: 'UTC',
      preferredGenres: const [],
      blockedGenres: const [],
      defaultMaxRuntimeMinutes: null,
      aiContextEnabled: false,
      blockedMovies: [for (final id in _s._blocked) _s._catalog[id]!],
    );
  }

  @override
  Future<void> unblock(int tmdbId) async {
    await _s._io();
    _s._blocked.remove(tmdbId);
  }
}

/// Null outside the preview build; Profile shows preview tools only when set.
final previewStoreProvider = Provider<PreviewStore?>((ref) => null);

/// Every fake, wired in one place for the explicit preview build.
List<Override> previewOverrides(PreviewStore store) => [
  previewStoreProvider.overrideWithValue(store),
  todayRepositoryProvider.overrideWithValue(FakeTodayRepository(store)),
  watchlistRepositoryProvider.overrideWithValue(FakeWatchlistRepository(store)),
  searchRepositoryProvider.overrideWithValue(FakeSearchRepository(store)),
  historyRepositoryProvider.overrideWithValue(FakeHistoryRepository(store)),
  profileRepositoryProvider.overrideWithValue(FakeProfileRepository(store)),
];
