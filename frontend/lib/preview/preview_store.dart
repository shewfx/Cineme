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

/// In-memory stand-in for the server in the UI-preview build only. It keeps
/// the documented cross-screen rules: Tonight picks only from the active
/// watchlist; removing or logging the current pick as watched clears it
/// without choosing a replacement; picks appear in recommendation history.
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
  TodayEnvelope? _current;
  int _seq = 0;

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

  /// Clears tonight's pick when its film leaves the eligible inventory.
  void _supersedeIfCurrent(int tmdbId) {
    final current = _current?.recommendation;
    if (current == null || current.movie.tmdbId != tmdbId) return;
    final i = _records.indexWhere((r) => r.id == current.id);
    if (i >= 0) {
      final r = _records[i];
      _records[i] = RecommendationRecord(
        id: r.id,
        movie: r.movie,
        status: RecommendationStatus.superseded,
        createdAt: r.createdAt,
        desiredExperience: r.desiredExperience,
      );
    }
    _current = null;
  }

  void _archive(int tmdbId) {
    _active.removeWhere((e) => e.movie.tmdbId == tmdbId);
    _supersedeIfCurrent(tmdbId);
  }
}

class FakeTodayRepository implements TodayRepository {
  FakeTodayRepository(this._s);

  final PreviewStore _s;

  TodayEnvelope get _state =>
      _s._current ??
      (_s._active.isEmpty
          ? const TodayEnvelope.emptyWatchlist()
          : const TodayEnvelope.notStarted());

  @override
  Future<TodayEnvelope> today() async {
    await _s._io();
    return _state;
  }

  /// Not a ranking engine: each intent has a fixed, ordered list of films and
  /// the first one in the active watchlist inside the hard runtime cap is
  /// returned. Current mood is ignored, as it is by the real scorer (P4).
  @override
  Future<TodayEnvelope> choose(SessionContext context) async {
    await _s._io();
    if (_s._current != null || _s._active.isEmpty) return _state;
    final cap = context.maxRuntimeMinutes;
    final active = {for (final e in _s._active) e.movie.tmdbId: e.movie};
    for (final (tmdbId, genreId) in previewScript[context.desiredExperience]!) {
      final movie = active[tmdbId];
      final runtime = movie?.runtimeMinutes;
      // Unknown runtime is excluded under a cap, never treated as zero.
      if (movie == null ||
          (cap != null && (runtime == null || runtime > cap))) {
        continue;
      }
      final recommendation = Recommendation(
        id: _s._id('r'),
        movie: movie,
        reasons: [
          if (context.desiredExperience == DesiredExperience.surprise)
            const SurpriseChosen()
          else
            GenreMatchesIntent(
              genre: movie.genres.firstWhere((g) => g.id == genreId),
              intent: context.desiredExperience,
            ),
          if (cap != null)
            FitsRuntime(runtimeMinutes: runtime!, capMinutes: cap),
        ],
      );
      _s._records.insert(
        0,
        RecommendationRecord(
          id: recommendation.id,
          movie: movie,
          status: RecommendationStatus.offered,
          createdAt: _s.now(),
          desiredExperience: context.desiredExperience,
        ),
      );
      return _s._current = TodayEnvelope(
        state: TodayStatus.offered,
        context: context,
        recommendation: recommendation,
      );
    }
    // ponytail: no_match state is out of P1 scope so far; scripted lists end
    // with a film of 90 minutes or less unless it was removed.
    throw StateError('No scripted preview film fits this context.');
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
    for (final e in _s._active) {
      if (e.movie.tmdbId == tmdbId) {
        return WatchlistAddResult(entry: e, alreadyPresent: true);
      }
    }
    // A restored entry gets a fresh added_at, like a new one.
    final entry = WatchlistEntry(
      id: _s._id('w'),
      movie: movie,
      addedAt: _s.now(),
    );
    _s._active.insert(0, entry);
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
    final viewing = Viewing(
      id: _s._id('v'),
      movie: movie,
      watchedAt: null,
      recordedAt: _s.now(),
      rating: null,
    );
    _s._viewings.insert(0, viewing);
    _s._archive(
      tmdbId,
    ); // archives the entry and clears it if it was tonight's pick
    return RecordWatchedResult(viewing: viewing, alreadyRecorded: false);
  }
}

class FakeProfileRepository implements ProfileRepository {
  FakeProfileRepository(this._s);

  final PreviewStore _s;

  @override
  Future<Profile> profile() async {
    await _s._io();
    return const Profile(
      displayName: null,
      timezone: 'UTC',
      preferredGenres: [],
      blockedGenres: [],
      defaultMaxRuntimeMinutes: null,
      aiContextEnabled: false,
      blockedMovies: [],
    );
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
