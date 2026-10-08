import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cineme/app.dart';
import 'package:cineme/core/config/app_config.dart';
import 'package:cineme/core/network/api_client.dart';
import 'package:cineme/core/widgets/movie_poster.dart';
import 'package:cineme/features/auth/data/account_repository.dart';
import 'package:cineme/features/history/data/history_repository.dart';
import 'package:cineme/features/availability/data/availability_repository.dart';
import 'package:cineme/features/auth/data/auth_repository.dart';
import 'package:cineme/features/preferences/data/profile_repository.dart';
import 'package:cineme/features/search/application/search_controller.dart';
import 'package:cineme/features/search/data/search_repository.dart';
import 'package:cineme/features/movies/data/movie_details_repository.dart';
import 'package:cineme/features/movies/presentation/movie_details_page.dart';
import 'package:cineme/features/watchlist/data/watchlist_repository.dart';
import 'package:cineme/preview/preview_store.dart';
import 'package:cineme/shared/models/inventory.dart';
import 'package:cineme/shared/models/movie.dart';
import 'package:cineme/shared/models/profile.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'nav_finders.dart';

/// In-memory stand-in for the Cinemé API (not TMDB): per-user watchlists keyed
/// by the bearer token, documented error envelopes, scriptable failures.
class FakeCinemeApi implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final _lists = <String, List<Map<String, dynamic>>>{};
  final blockedIds = <String, Set<int>>{};
  final viewingIds = <String, Set<int>>{};
  int _ids = 0;
  int? failStatus; // when set, every request answers with this envelope
  String failCode = 'DEPENDENCY_UNAVAILABLE';
  bool failDetails = false;
  bool failBlocks = false;
  bool failViewingWrites = false;
  bool failRemovals = false;

  static Map<String, dynamic> movie(
    int id,
    String title, {
    String? poster,
    bool canAdd = true,
    bool released = true,
  }) => {
    'tmdb_id': id,
    'title': title,
    'year': 2016,
    'runtime_minutes': null,
    'genre_ids': [18],
    'genres': [
      {'id': 18, 'name': 'Drama'},
    ],
    'poster_url': poster,
    'can_add': canAdd,
    'released': released,
  };

  final catalog = {
    329865: movie(
      329865,
      'Arrival',
      poster: 'https://image.tmdb.org/t/p/w500/a.jpg',
    ),
    14337: movie(14337, 'Primer'),
    888: movie(888, 'Future Film', released: false),
    890: movie(890, 'Adult Film', canAdd: false),
  };

  ResponseBody _json(int status, Object body) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );

  ResponseBody _error(int status, String code, String message) =>
      _json(status, {
        'error': {
          'code': code,
          'message': message,
          'details': {},
          'retryable': false,
        },
        'request_id': 'r',
      });

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final user = (options.headers['Authorization'] as String?)?.replaceFirst(
      'Bearer ',
      '',
    );
    if (failStatus != null) {
      return _error(failStatus!, failCode, 'Scripted failure.');
    }
    if (user == null) {
      return _error(401, 'AUTH_REQUIRED', 'Sign in to continue.');
    }
    final list = _lists.putIfAbsent(user, () => []);
    final blocks = blockedIds.putIfAbsent(user, () => {});
    final viewings = viewingIds.putIfAbsent(user, () => {});
    final path = options.path;
    if (options.method == 'GET' && path == '/api/v1/movies/search') {
      final q = (options.queryParameters['q'] as String).toLowerCase();
      final hits = catalog.values.where(
        (m) => (m['title'] as String).toLowerCase().contains(q),
      );
      return _json(200, {
        'page': 1,
        'total_pages': 1,
        'results': hits.toList(),
      });
    }
    if (options.method == 'GET' &&
        RegExp(r'^/api/v1/movies/\d+/availability$').hasMatch(path)) {
      final id = int.parse(path.split('/')[4]);
      return _json(200, {
        'tmdb_id': id,
        'region': 'IN',
        'link': null,
        'streaming': [
          {'id': 5, 'name': 'Other Screen', 'logo_url': null},
          {'id': 4, 'name': 'Apple TV', 'logo_url': null},
          {'id': 1, 'name': 'Netflix', 'logo_url': null},
          {'id': 2, 'name': 'Amazon Prime Video', 'logo_url': null},
        ],
        'free': [
          {'id': 3, 'name': 'JioHotstar', 'logo_url': null},
        ],
        'rent': <Object?>[],
        'buy': <Object?>[],
        'fetched_at': null,
        'stale': false,
      });
    }
    if (options.method == 'POST' &&
        RegExp(r'^/api/v1/me/blocks/\d+$').hasMatch(path)) {
      if (failBlocks) {
        return _error(503, 'DEPENDENCY_UNAVAILABLE', 'Try again shortly.');
      }
      final id = int.parse(path.split('/').last);
      final already = !blocks.add(id);
      return _json(200, {'blocked': true, 'already_blocked': already});
    }
    if (options.method == 'POST' && path == '/api/v1/viewings') {
      if (failViewingWrites) {
        return _error(503, 'DEPENDENCY_UNAVAILABLE', 'Try again shortly.');
      }
      final id = (options.data as Map)['tmdb_id'] as int;
      final movie = catalog[id];
      if (movie == null) {
        return _error(404, 'NOT_FOUND', 'That film was not found.');
      }
      final already = !viewings.add(id);
      list.removeWhere((entry) => (entry['movie'] as Map)['tmdb_id'] == id);
      return _json(200, {
        'already_recorded': already,
        'viewing': {
          'id': 'viewing-$id',
          'movie': movie,
          'watched_at': null,
          'recorded_at': '2026-10-02T10:00:00Z',
          'rating': null,
          'version': 1,
        },
      });
    }
    if (options.method == 'GET' && path == '/api/v1/viewings') {
      return _json(200, {
        'items': [
          for (final id in viewings)
            {
              'id': 'viewing-$id',
              'movie': catalog[id],
              'watched_at': null,
              'recorded_at': '2026-10-02T10:00:00Z',
              'rating': null,
              'version': 1,
            },
        ],
        'next_cursor': null,
      });
    }
    if (options.method == 'GET' &&
        RegExp(r'^/api/v1/movies/\d+$').hasMatch(path)) {
      if (failDetails) {
        return _error(503, 'DEPENDENCY_UNAVAILABLE', 'Try again shortly.');
      }
      final id = int.parse(path.split('/').last);
      final movie = catalog[id];
      if (movie == null) {
        return _error(404, 'NOT_FOUND', 'That film was not found.');
      }
      return _json(200, {
        ...movie,
        'release_date': '2016-11-11',
        'overview': 'A linguist is asked to communicate with visitors.',
        'original_title': null,
        'original_language': 'en',
        'vote_count': 1200,
        'metadata_fetched_at': '2026-10-02T10:00:00Z',
        'stale': false,
        'traits': {
          'pace': null,
          'complexity': null,
          'heaviness': null,
          'source': null,
        },
      });
    }
    if (options.method == 'GET' && path == '/api/v1/watchlist') {
      return _json(200, {'items': list.reversed.toList(), 'next_cursor': null});
    }
    if (options.method == 'POST' && path == '/api/v1/watchlist') {
      final id = (options.data as Map)['tmdb_id'] as int;
      final m = catalog[id];
      if (m == null) {
        return _error(404, 'NOT_FOUND', 'That film was not found.');
      }
      if (m['can_add'] != true) {
        return _error(422, 'MOVIE_INELIGIBLE', "This film can't be added.");
      }
      final existing = list.where((e) => (e['movie'] as Map)['tmdb_id'] == id);
      if (existing.isNotEmpty) {
        return _json(200, {'entry': existing.first, 'already_present': true});
      }
      final entry = {
        'id': 'entry-${++_ids}',
        'movie': m,
        'added_at': DateTime.utc(2026, 10, 2, 10, _ids).toIso8601String(),
        'source_type': 'manual',
      };
      list.add(entry);
      return _json(201, {'entry': entry, 'already_present': false});
    }
    if (options.method == 'DELETE' && path.startsWith('/api/v1/watchlist/')) {
      if (failRemovals) {
        return _error(503, 'DEPENDENCY_UNAVAILABLE', 'Try again shortly.');
      }
      final id = path.split('/').last;
      final before = list.length;
      list.removeWhere((e) => e['id'] == id);
      return before == list.length
          ? _error(404, 'NOT_FOUND', 'That watchlist entry was not found.')
          : _json(200, {'removed': true});
    }
    return _error(404, 'NOT_FOUND', 'Not found.');
  }

  @override
  void close({bool force = false}) {}
}

class _StaticMovieDetails implements MovieDetailsRepository {
  @override
  Future<MovieDetails> details(int tmdbId) async => MovieDetails(
    movie: Movie(
      tmdbId: tmdbId,
      title: 'Arrival',
      year: 2016,
      runtimeMinutes: 116,
      genres: const [Genre(18, 'Drama')],
    ),
    overview: 'A linguist is asked to communicate with visitors.',
    stale: false,
  );
}

class _PendingMovieDetails implements MovieDetailsRepository {
  final completer = Completer<MovieDetails>();

  @override
  Future<MovieDetails> details(int tmdbId) => completer.future;
}

class FakeAuth implements AuthRepository {
  FakeAuth(this._user);

  AuthUser? _user;
  final _changes = StreamController<AuthUser?>.broadcast();

  void emit(AuthUser? u) {
    _user = u;
    _changes.add(u);
  }

  @override
  AuthUser? get currentUser => _user;

  @override
  Stream<AuthUser?> userChanges() async* {
    yield _user;
    yield* _changes.stream;
  }

  @override
  Future<String?> accessToken() async => _user?.id;

  @override
  Future<void> signIn(String email, String password) async {}

  @override
  Future<SignUpOutcome> signUp(String email, String password) async =>
      SignUpOutcome.signedIn;

  @override
  Future<void> signOut() async => emit(null);
}

class FakeAccount implements AccountRepository {
  FakeAccount([this.api]);

  final ApiClient? api;

  @override
  Future<void> unblock(int tmdbId) async {}

  @override
  Future<void> block(int tmdbId) async {
    final client = api;
    if (client != null) await ApiAccountRepository(client).block(tmdbId);
  }

  @override
  Future<void> setRegion(String? countryCode) async {}

  @override
  Future<void> completeOnboarding() async {}

  @override
  Future<List<(String, String)>> regions() async => const [('IN', 'India')];

  @override
  Future<void> bootstrap() async {}

  @override
  Future<Profile> me() async => const Profile(
    displayName: null,
    timezone: 'UTC',
    preferredGenres: [],
    blockedGenres: [],
    defaultMaxRuntimeMinutes: null,
    aiContextEnabled: false,
    blockedMovies: null,
  );
}

const alice = AuthUser(id: 'alice', email: 'a@example.test');
const bob = AuthUser(id: 'bob', email: 'b@example.test');

class Rig {
  Rig() {
    api = ApiClient(
      Dio(BaseOptions(baseUrl: 'http://api.test'))..httpClientAdapter = server,
      () => auth.accessToken(),
    );
  }

  final server = FakeCinemeApi();
  final auth = FakeAuth(alice);
  late final ApiClient api;

  Widget app() => ProviderScope(
    retry: noAutomaticRetry,
    overrides: [
      appConfigProvider.overrideWithValue(
        const AppConfig(
          apiBaseUrl: 'http://api.test',
          supabaseUrl: 'https://x.supabase.co',
          supabasePublishableKey: 'sb_publishable_test',
        ),
      ),
      authRepositoryProvider.overrideWithValue(auth),
      accountRepositoryProvider.overrideWithValue(FakeAccount()),
      profileRepositoryProvider.overrideWithValue(
        AccountProfileRepository(FakeAccount(api)),
      ),
      watchlistRepositoryProvider.overrideWithValue(
        ApiWatchlistRepository(api),
      ),
      searchRepositoryProvider.overrideWithValue(ApiSearchRepository(api)),
      historyRepositoryProvider.overrideWithValue(ApiHistoryRepository(api)),
      availabilityRepositoryProvider.overrideWithValue(
        ApiAvailabilityRepository(api),
      ),
      movieDetailsRepositoryProvider.overrideWithValue(
        ApiMovieDetailsRepository(api),
      ),
    ],
    child: const CinemeApp(),
  );
}

Future<void> goTab(WidgetTester tester, String label) async {
  await tester.tap(navTab(label));
  await tester.pumpAndSettle();
}

Future<void> search(WidgetTester tester, String q) async {
  await tester.enterText(find.byType(TextField), q);
  await tester.pump(searchDebounce);
  await tester.pumpAndSettle();
}

void main() {
  group('Real repositories', () {
    test(
      'Never recommend uses the existing idempotent block endpoint',
      () async {
        final rig = Rig();
        await ApiAccountRepository(rig.api).block(329865);
        final request = rig.server.requests.last;
        expect(request.method, 'POST');
        expect(request.path, '/api/v1/me/blocks/329865');
        expect(request.headers['Idempotency-Key'], isNotNull);
      },
    );

    test('add sends only tmdb_id with a fresh UUID key; duplicate is already_present', () async {
      final rig = Rig();
      final repo = ApiWatchlistRepository(rig.api);
      final first = await repo.add(329865);
      final again = await repo.add(329865);
      expect(first.alreadyPresent, isFalse);
      expect(again.alreadyPresent, isTrue);
      expect(again.entry.id, first.entry.id);
      final posts = rig.server.requests
          .where((r) => r.method == 'POST')
          .toList();
      expect(posts.first.data, {'tmdb_id': 329865});
      final keys = posts
          .map((r) => r.headers['Idempotency-Key'] as String)
          .toSet();
      expect(
        keys,
        hasLength(2),
        reason: 'each deliberate tap is its own command',
      );
      for (final k in keys) {
        expect(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ).hasMatch(k),
          isTrue,
        );
      }
    });

    test('documented add outcomes become InventoryConflict', () async {
      final repo = ApiWatchlistRepository(Rig().api);
      await expectLater(
        repo.add(890),
        throwsA(
          isA<InventoryConflict>().having(
            (c) => c.code,
            'code',
            'MOVIE_INELIGIBLE',
          ),
        ),
      );
      await expectLater(repo.add(424242), throwsA(isA<ApiError>()));
    });

    test(
      'list keeps unknowns null and remove uses DELETE with a key',
      () async {
        final rig = Rig();
        final repo = ApiWatchlistRepository(rig.api);
        final added = await repo.add(14337);
        final page = await repo.list();
        expect(page.items.single.movie.runtimeMinutes, isNull);
        expect(page.items.single.movie.posterUrl, isNull);
        await repo.remove(added.entry.id);
        final del = rig.server.requests.last;
        expect(del.method, 'DELETE');
        expect(del.path, '/api/v1/watchlist/${added.entry.id}');
        expect(del.headers['Idempotency-Key'], isNotNull);
        expect((await repo.list()).items, isEmpty);
      },
    );

    test(
      'search maps can_add and poster_url; malformed data is an error',
      () async {
        final rig = Rig();
        final results = (await ApiSearchRepository(rig.api).search('arr'))
            .results;
        expect(
          results.single.movie.posterUrl,
          startsWith('https://image.tmdb.org/'),
        );
        expect(rig.server.requests.last.queryParameters, {
          'q': 'arr',
          'page': 1,
        });
        final future = (await ApiSearchRepository(rig.api).search('future'))
            .results
            .single;
        // Upcoming films can be saved but are not released (Tonight-eligible).
        expect(future.canAdd, isTrue);
        expect(future.movie.released, isFalse);
        expect(
          (await ApiWatchlistRepository(rig.api).add(888)).entry.movie.released,
          isFalse,
        );

        // A result missing required fields is a visible error, not a gap.
        rig.server.catalog[1] = {'tmdb_id': 1, 'title': 'Broken 1'};
        await expectLater(
          ApiSearchRepository(rig.api).search('broken'),
          throwsA(
            isA<ApiError>().having((e) => e.code, 'code', 'MALFORMED_RESPONSE'),
          ),
        );
      },
    );

    testWidgets(
      'posters: network image when present, placeholder when missing',
      (tester) async {
        // Posters are the default layout; this checks the list rows' artwork.
        SharedPreferences.setMockInitialValues({'watchlist_layout': 'list'});
        final rig = Rig();
        // Seed through the real client outside the fake test clock.
        await tester.runAsync(
          () => rig.api.post(
            '/api/v1/watchlist',
            body: {'tmdb_id': 329865},
            idempotencyKey: 'k1',
          ),
        );
        // Seed through the real client outside the fake test clock.
        await tester.runAsync(
          () => rig.api.post(
            '/api/v1/watchlist',
            body: {'tmdb_id': 14337},
            idempotencyKey: 'k2',
          ),
        );
        await tester.pumpWidget(rig.app());
        await tester.pumpAndSettle();
        await goTab(tester, 'Watchlist');

        Finder posterImages(String title) => find.descendant(
          of: find
              .ancestor(of: find.text(title), matching: find.byType(Row))
              .first,
          matching: find.byType(Image),
        );
        expect(posterImages('Arrival'), findsOneWidget);
        expect(
          posterImages('Primer'),
          findsNothing,
          reason: 'no URL, designed placeholder',
        );
        expect(find.byType(MoviePoster), findsNWidgets(2));
      },
    );

    testWidgets('tapping a watchlist poster opens on-demand movie details', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'watchlist_layout': 'posters'});
      final rig = Rig();
      await tester.runAsync(
        () => rig.api.post(
          '/api/v1/watchlist',
          body: {'tmdb_id': 329865},
          idempotencyKey: 'k-detail',
        ),
      );
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');

      await tester.tap(find.text('Arrival'));
      await tester.pumpAndSettle();

      expect(find.text('Movie details'), findsOneWidget);
      expect(
        find.text('A linguist is asked to communicate with visitors.'),
        findsOneWidget,
      );
      expect(find.text('Where to watch'), findsOneWidget);
      expect(find.text('Netflix'), findsOneWidget);
      expect(find.text('Amazon Prime Video'), findsOneWidget);
      expect(find.text('JioHotstar (free)'), findsOneWidget);
      expect(find.text('Apple TV'), findsNothing);
      await tester.ensureVisible(find.text('+2 more'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('+2 more'));
      await tester.pumpAndSettle();
      expect(find.text('Apple TV'), findsOneWidget);
      expect(find.text('Other Screen'), findsOneWidget);
      expect(
        rig.server.requests.any(
          (request) =>
              request.method == 'GET' &&
              request.path == '/api/v1/movies/329865',
        ),
        isTrue,
      );
      expect(find.text('Why this film?'), findsNothing);
    });

    testWidgets('tapping a list row opens movie details', (tester) async {
      SharedPreferences.setMockInitialValues({'watchlist_layout': 'list'});
      final rig = Rig();
      await tester.runAsync(
        () => rig.api.post(
          '/api/v1/watchlist',
          body: {'tmdb_id': 329865},
          idempotencyKey: 'k-list-detail',
        ),
      );
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');
      await tester.tap(find.text('Arrival'));
      await tester.pumpAndSettle();
      expect(find.text('Overview'), findsOneWidget);
    });

    testWidgets('movie details show a restrained loading state', (
      tester,
    ) async {
      final repository = _PendingMovieDetails();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            movieDetailsRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(home: MovieDetailsPage(tmdbId: 329865)),
        ),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Movie details'), findsOneWidget);

      repository.completer.complete(
        MovieDetails(
          movie: const Movie(
            tmdbId: 329865,
            title: 'Arrival',
            year: 2016,
            runtimeMinutes: null,
            genres: [],
          ),
          overview: 'A linguist is asked to communicate with visitors.',
          stale: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Overview'), findsOneWidget);
    });

    testWidgets('a stale Watchlist tile shows a missing-movie state', (
      tester,
    ) async {
      final rig = Rig();
      await tester.runAsync(
        () => rig.api.post(
          '/api/v1/watchlist',
          body: {'tmdb_id': 329865},
          idempotencyKey: 'k-missing-detail',
        ),
      );
      rig.server.catalog.remove(329865);
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');
      await tester.tap(find.text('Arrival'));
      await tester.pumpAndSettle();
      expect(find.text('Movie not found'), findsOneWidget);
      expect(
        find.text('This film is no longer available from the movie database.'),
        findsOneWidget,
      );
    });

    testWidgets('malformed movie identifiers show the safe not-found route', (
      tester,
    ) async {
      final rig = Rig();
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');
      final router = GoRouter.of(tester.element(find.byType(Scaffold).first));

      for (final path in ['/movies/not-a-number', '/movies/2147483648']) {
        router.go(path);
        await tester.pumpAndSettle();
        expect(
          find.text('This movie link is invalid or out of date.'),
          findsOneWidget,
        );
      }
    });

    testWidgets('detail layout fits a narrow phone at large text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            movieDetailsRepositoryProvider.overrideWithValue(
              _StaticMovieDetails(),
            ),
          ],
          child: MaterialApp(
            home: MovieDetailsPage(
              tmdbId: 329865,
              entry: WatchlistEntry(
                id: 'entry-1',
                movie: const Movie(
                  tmdbId: 329865,
                  title: 'Arrival',
                  year: 2016,
                  runtimeMinutes: null,
                  genres: [],
                ),
                addedAt: DateTime.utc(2026, 10, 1),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('movie-details-scroll')),
        findsOneWidget,
      );
      final layoutException = tester.takeException();
      expect(layoutException, isNull, reason: '$layoutException');
    });

    testWidgets(
      'detail actions keep removal, watched history, and blocks distinct',
      (tester) async {
        final rig = Rig();
        await tester.runAsync(
          () => rig.api.post(
            '/api/v1/watchlist',
            body: {'tmdb_id': 329865},
            idempotencyKey: 'k-detail-actions',
          ),
        );
        await tester.pumpWidget(rig.app());
        await tester.pumpAndSettle();
        await goTab(tester, 'Watchlist');
        await tester.tap(find.text('Arrival'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Never recommend'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Never recommend').last);
        await tester.pumpAndSettle();
        expect(rig.server.blockedIds['alice'], contains(329865));
        expect(find.text('Never recommend · undo in Profile'), findsOneWidget);
        expect(rig.server._lists['alice'], hasLength(1));

        await tester.tap(find.text('Remove from watchlist'));
        await tester.pumpAndSettle();
        expect(find.text('Removed from watchlist'), findsOneWidget);
        expect(rig.server._lists['alice'], isEmpty);

        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        expect(rig.server._lists['alice'], hasLength(1));
        expect(find.text('Remove from watchlist'), findsOneWidget);

        await tester.tap(find.text('Mark watched'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Mark watched').last);
        await tester.pumpAndSettle();
        expect(rig.server.viewingIds['alice'], contains(329865));
        expect(rig.server._lists['alice'], isEmpty);
        expect(find.text('Watched · saved in History'), findsOneWidget);
        expect(rig.server.blockedIds['alice'], contains(329865));

        await goTab(tester, 'History');
        expect(find.text('Arrival'), findsOneWidget);
      },
    );

    testWidgets(
      'details error retries while keeping the Watchlist back stack',
      (tester) async {
        final rig = Rig()..server.failDetails = true;
        await tester.runAsync(
          () => rig.api.post(
            '/api/v1/watchlist',
            body: {'tmdb_id': 329865},
            idempotencyKey: 'k-detail-retry',
          ),
        );
        await tester.pumpWidget(rig.app());
        await tester.pumpAndSettle();
        await goTab(tester, 'Watchlist');
        await tester.tap(find.text('Arrival'));
        await tester.pumpAndSettle();
        expect(find.text('Retry'), findsOneWidget);

        rig.server.failDetails = false;
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.text('Overview'), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('Watchlist'), findsOneWidget);
      },
    );

    testWidgets('failed detail actions preserve inventory and retry controls', (
      tester,
    ) async {
      final rig = Rig()
        ..server.failBlocks = true
        ..server.failViewingWrites = true
        ..server.failRemovals = true;
      await tester.runAsync(
        () => rig.api.post(
          '/api/v1/watchlist',
          body: {'tmdb_id': 329865},
          idempotencyKey: 'k-detail-failures',
        ),
      );
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');
      await tester.tap(find.text('Arrival'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Never recommend'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Never recommend').last);
      await tester.pumpAndSettle();
      expect(find.text('Never recommend'), findsOneWidget);
      expect(rig.server._lists['alice'], hasLength(1));

      await tester.tap(find.text('Mark watched'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark watched').last);
      await tester.pumpAndSettle();
      expect(find.text('Mark watched'), findsOneWidget);
      expect(rig.server._lists['alice'], hasLength(1));

      await tester.tap(find.text('Remove from watchlist'));
      await tester.pumpAndSettle();
      expect(find.text('Remove from watchlist'), findsOneWidget);
      expect(rig.server._lists['alice'], hasLength(1));
    });

    testWidgets('backend failure shows the error, then Retry recovers', (
      tester,
    ) async {
      final rig = Rig()..server.failStatus = 503;
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');
      expect(find.text('Retry'), findsOneWidget);
      expect(
        find.text('Your watchlist is empty'),
        findsNothing,
        reason: 'not mislabelled empty',
      );

      rig.server.failStatus = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Your watchlist is empty'), findsOneWidget);
    });

    testWidgets('an auth failure is an error, never fake data', (tester) async {
      final rig = Rig()
        ..server.failStatus = 401
        ..server.failCode = 'TOKEN_INVALID';
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byType(MoviePoster), findsNothing);
    });

    testWidgets("account switch shows only the new user's watchlist", (
      tester,
    ) async {
      final rig = Rig();
      // Seed through the real client outside the fake test clock.
      await tester.runAsync(
        () => rig.api.post(
          '/api/v1/watchlist',
          body: {'tmdb_id': 329865},
          idempotencyKey: 'k',
        ),
      );
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');
      expect(find.text('Arrival'), findsOneWidget);

      rig.auth.emit(null);
      await tester.pumpAndSettle();
      rig.auth.emit(bob);
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');
      expect(find.text('Arrival'), findsNothing);
      expect(find.text('Your watchlist is empty'), findsOneWidget);
    });
  });

  testWidgets('preview build keeps its fakes and never builds an API client', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        retry: noAutomaticRetry,
        overrides: previewOverrides(PreviewStore(latency: Duration.zero)),
        child: const CinemeApp(),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CinemeApp)),
    );
    expect(
      container.read(watchlistRepositoryProvider),
      isA<FakeWatchlistRepository>(),
    );
    expect(
      container.read(searchRepositoryProvider),
      isA<FakeSearchRepository>(),
    );
    expect(container.read(authRepositoryProvider), isNull);
  });
}
