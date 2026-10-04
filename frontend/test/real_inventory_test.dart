import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cineme/app.dart';
import 'package:cineme/core/config/app_config.dart';
import 'package:cineme/core/network/api_client.dart';
import 'package:cineme/core/widgets/movie_poster.dart';
import 'package:cineme/features/auth/data/account_repository.dart';
import 'package:cineme/features/auth/data/auth_repository.dart';
import 'package:cineme/features/preferences/data/profile_repository.dart';
import 'package:cineme/features/search/application/search_controller.dart';
import 'package:cineme/features/search/data/search_repository.dart';
import 'package:cineme/features/watchlist/data/watchlist_repository.dart';
import 'package:cineme/preview/preview_store.dart';
import 'package:cineme/shared/models/inventory.dart';
import 'package:cineme/shared/models/profile.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'nav_finders.dart';

/// In-memory stand-in for the Cinemé API (not TMDB): per-user watchlists keyed
/// by the bearer token, documented error envelopes, scriptable failures.
class FakeCinemeApi implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final _lists = <String, List<Map<String, dynamic>>>{};
  int _ids = 0;
  int? failStatus; // when set, every request answers with this envelope
  String failCode = 'DEPENDENCY_UNAVAILABLE';

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
  @override
  Future<void> unblock(int tmdbId) async {}

  @override
  Future<void> setRegion(String? countryCode) async {}

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
        AccountProfileRepository(FakeAccount()),
      ),
      watchlistRepositoryProvider.overrideWithValue(
        ApiWatchlistRepository(api),
      ),
      searchRepositoryProvider.overrideWithValue(ApiSearchRepository(api)),
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
