import 'dart:convert';
import 'dart:typed_data';

import 'package:cineme/app.dart';
import 'package:cineme/core/config/app_config.dart';
import 'package:cineme/core/network/api_client.dart';
import 'package:cineme/core/widgets/movie_poster.dart';
import 'package:cineme/features/auth/data/account_repository.dart';
import 'package:cineme/features/auth/data/auth_repository.dart';
import 'package:cineme/features/preferences/data/profile_repository.dart';
import 'package:cineme/features/availability/data/availability_repository.dart';
import 'package:cineme/features/today/data/today_repository.dart';
import 'package:cineme/preview/preview_store.dart';
import 'package:cineme/shared/models/session_context.dart';
import 'package:cineme/shared/models/today_state.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'real_inventory_test.dart' show FakeAccount, FakeAuth, alice, bob;

Map<String, dynamic> film(int id, String title, int? runtime) => {
  'tmdb_id': id,
  'title': title,
  'year': 2001,
  'runtime_minutes': runtime,
  'genre_ids': [18, 53],
  'genres': [
    {'id': 18, 'name': 'Drama'},
    {'id': 53, 'name': 'Thriller'},
  ],
  'poster_url': null,
  'can_add': true,
  'released': true,
};

/// Scripted stand-in for the Today part of the Cinemé API contract. The real
/// ranking/state rules are tested on the backend; this checks the client
/// sends the documented commands and renders the documented envelopes.
class FakeTodayApi implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int? failStatus;
  String failCode = 'DEPENDENCY_UNAVAILABLE';

  final films = [
    film(104, 'Run Lola Run', 81),
    film(329865, 'Arrival', 116),
    film(14337, 'Primer', 77),
    film(501, 'Extra One', 95),
    film(502, 'Extra Two', 99),
  ];
  bool emptyWatchlist = false;

  int version = 0;
  Map<String, dynamic>? context;
  Map<String, dynamic>? current;
  int rejections = 0;
  int attempts = 0;
  final offered = <int>{};
  int _ids = 0;

  /// Mutations actually applied (replays don't count).
  int processed = 0;

  /// Apply the next N mutations, then lose the response (ambiguous failure).
  int dropResponses = 0;
  final _ledger = <String, (String, int, Object)>{};
  final keys = <String>[];

  /// GET /movies/{id}/availability bodies by film; missing -> 503.
  final availability = <int, Map<String, dynamic>>{};

  Map<String, dynamic> get state {
    final String s;
    if (current != null) {
      s = current!['status'] as String;
    } else if (emptyWatchlist) {
      s = 'empty_watchlist';
    } else if (context == null) {
      s = 'not_started';
    } else if (rejections >= 3) {
      s = 'paused';
    } else {
      s = 'ready';
    }
    return {
      'state': s,
      'local_date': '2026-10-02',
      'session': context == null
          ? null
          : {
              'id': 's1',
              'version': version,
              'timezone': 'UTC',
              'context': context,
              'effective_context': context,
              'overridden_fields': <String>[],
              'rejection_count': rejections,
              'attempt_count': attempts,
              'completed_at': null,
            },
      'recommendation': current,
    };
  }

  void _select() {
    attempts++;
    final cap = context!['max_runtime_minutes'] as int?;
    final avoid = {...(context!['avoid_genre_ids'] as List? ?? [])};
    final eligible = [
      for (final f in films)
        if (!offered.contains(f['tmdb_id']) &&
            (cap == null ||
                (f['runtime_minutes'] != null &&
                    (f['runtime_minutes'] as int) <= cap)) &&
            !(f['genre_ids'] as List).any(avoid.contains))
          f,
    ];
    final id = 'rec-${++_ids}';
    if (eligible.isEmpty) {
      current = {
        'id': id,
        'status': 'no_match',
        'movie': null,
        'total_score': null,
        'engine_version': 'weighted_v1',
        'explanation': 'None fit.',
        'reasons': <Object>[],
        'uncertainties': <Object>[],
        'created_at': '2026-10-02T20:00:00Z',
        'no_match_summary': {
          'candidate_count': films.length,
          'primary_exclusion_counts': {'runtime_exceeded': films.length},
          'suggested_actions': ['edit_runtime', 'add_movies'],
        },
      };
      return;
    }
    final f = eligible.first;
    offered.add(f['tmdb_id'] as int);
    current = {
      'id': id,
      'status': 'offered',
      'movie': f,
      'total_score': 70.5,
      'engine_version': 'weighted_v1',
      'explanation': '',
      'reasons': [
        if (cap != null)
          {
            'code': 'fits_runtime',
            'values': {},
            'source': 'metadata',
            'text':
                '${f['runtime_minutes']} minutes, within your $cap-minute limit.',
          },
        {
          'code': 'context_genre_proxy',
          'values': {},
          'source': 'context',
          'text': 'Its genre (Thriller) fits your “Something exciting” choice.',
        },
        {
          'code': 'waiting_in_watchlist',
          'values': {},
          'source': 'watchlist',
          'text': 'In your watchlist for 3 months.',
        },
      ],
      'uncertainties': <Object>[],
      'created_at': '2026-10-02T20:00:00Z',
      'no_match_summary': null,
    };
  }

  ResponseBody _json(int status, Object body) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );

  ResponseBody _error(int status, String code) => _json(status, {
    'error': {'code': code, 'message': code, 'details': {}, 'retryable': false},
    'request_id': 'r',
  });

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (failStatus != null) return _error(failStatus!, failCode);
    final path = options.path;
    final body = (options.data as Map?)?.cast<String, dynamic>() ?? {};
    if (options.method == 'GET' && path == '/api/v1/today') {
      return _json(200, state);
    }
    if (options.method == 'GET' && path.endsWith('/availability')) {
      final id = int.parse(path.split('/')[4]);
      final a = availability[id];
      return a == null
          ? _error(503, 'DEPENDENCY_UNAVAILABLE')
          : _json(200, {'tmdb_id': id, ...a});
    }
    if (options.method == 'GET' &&
        path.startsWith('/api/v1/recommendations/')) {
      return _json(200, {
        'recommendation': current,
        'context': context,
        'effective_context': context,
        'feedback': null,
        'breakdown': {
          'components': {'G': .5, 'C': .8, 'D': .5, 'A': 1, 'R': 1, 'Q': .6},
          'weights': {'G': 35, 'C': 30, 'D': 10, 'A': 10, 'R': 10, 'Q': 5},
          'contributions': {
            'G': 17.5,
            'C': 24,
            'D': 5,
            'A': 10,
            'R': 10,
            'Q': 3,
          },
        },
        'config_version': 'weights_v1',
      });
    }
    // Idempotency ledger, like the server: same key + same request replays.
    final key = options.headers['Idempotency-Key'] as String;
    keys.add(key);
    final fingerprint = '${options.method} $path ${jsonEncode(body)}';
    final stored = _ledger[key];
    if (stored != null) {
      return stored.$1 == fingerprint
          ? _json(stored.$2, stored.$3)
          : _error(409, 'IDEMPOTENCY_CONFLICT');
    }
    final response = _mutate(path, body);
    final (status, json) = response;
    if (status < 300) {
      processed++;
      _ledger[key] = (fingerprint, status, json);
    }
    if (dropResponses > 0) {
      dropResponses--;
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.receiveTimeout,
      );
    }
    return status < 300 ? _json(status, json) : _error(status, json as String);
  }

  /// Applies one command; (status, body) or (status, error code).
  (int, Object) _mutate(String path, Map<String, dynamic> body) {
    if (body['expected_session_version'] != version) {
      return (409, 'VERSION_CONFLICT');
    }
    if (path == '/api/v1/today/choose') {
      if (body['context'] == null && context == null) {
        return (422, 'CONTEXT_REQUIRED');
      }
      final next = body['context'] as Map<String, dynamic>?;
      final changed =
          next != null &&
          context != null &&
          next['desired_experience'] != context!['desired_experience'];
      if (next != null) context = next;
      if (current != null && current!['status'] != 'no_match' && !changed) {
        return (200, state);
      }
      if (rejections >= 3 && body['continue_after_pause'] != true && !changed) {
        return (409, 'CONTEXT_REVIEW_REQUIRED');
      }
      version++;
      _select();
      return (201, state);
    }
    if (path == '/api/v1/today/context') {
      context = body['context'] as Map<String, dynamic>;
      current = null;
      version++;
      return (200, state);
    }
    if (path.endsWith('/accept')) {
      current = {...current!, 'status': 'accepted'};
      version++;
      return (200, state);
    }
    if (path.endsWith('/reject')) {
      rejections++;
      current = null;
      version++;
      final details = body['details'] as Map;
      if (details['max_runtime_minutes'] != null) {
        context = {
          ...context!,
          'max_runtime_minutes': details['max_runtime_minutes'],
        };
      }
      if (details['avoid_genre_ids'] != null) {
        context = {...context!, 'avoid_genre_ids': details['avoid_genre_ids']};
      }
      var outcome = 'not_requested';
      if (body['choose_another'] == true) {
        if (rejections >= 3) {
          outcome = 'paused';
        } else {
          _select();
          outcome = current!['status'] == 'no_match' ? 'no_match' : 'selected';
        }
      }
      return (
        200,
        {
          'feedback': {
            'id': 'f',
            'reason': body['reason'],
            'created_at': '2026-10-02T20:00:00Z',
          },
          'viewing': body['reason'] == 'already_watched'
              ? {
                  'id': 'v1',
                  'movie': film(1, 'x', 90),
                  'watched_at': null,
                  'recorded_at': '2026-10-02T20:00:00Z',
                  'source': 'already_watched',
                  'rating': null,
                  'version': 1,
                  'recommendation_id': null,
                }
              : null,
          'today': state,
          'replacement_outcome': outcome,
        },
      );
    }
    return (404, 'NOT_FOUND');
  }

  @override
  void close({bool force = false}) {}

  List<RequestOptions> commands(String suffix) => [
    for (final r in requests)
      if (r.method != 'GET' && r.path.endsWith(suffix)) r,
  ];
}

class TodayRig {
  TodayRig() {
    api = ApiClient(
      Dio(BaseOptions(baseUrl: 'http://api.test'))..httpClientAdapter = server,
      () => auth.accessToken(),
    );
  }

  final server = FakeTodayApi();
  final auth = FakeAuth(alice);
  late final ApiClient api;

  Widget app({bool canvas = false}) => ProviderScope(
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
      todayRepositoryProvider.overrideWithValue(ApiTodayRepository(api)),
      availabilityRepositoryProvider.overrideWithValue(
        ApiAvailabilityRepository(api),
      ),
    ],
    child: CinemeApp(centredCanvas: canvas),
  );
}

Future<TodayRig> start(WidgetTester tester, [TodayRig? rig]) async {
  rig ??= TodayRig();
  await tester.pumpWidget(rig.app());
  await tester.pumpAndSettle();
  return rig;
}

Future<void> tapText(WidgetTester tester, String text) async {
  // A long option sheet at large text builds lazily: scroll it like a user.
  if (find.text(text).evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      find.text(text),
      80,
      scrollable: find.byType(Scrollable).last,
    );
  }
  await tester.ensureVisible(find.text(text).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

Future<void> pickExciting(WidgetTester tester, {String? time}) async {
  // Three compact selectors: open the field, then choose from its sheet.
  await tapText(tester, 'Choose one');
  await tapText(tester, 'Exciting');
  if (time != null) {
    await tapText(tester, 'Any length');
    await tapText(tester, time);
  }
  await tapText(tester, 'Pick my movie');
}

void main() {
  group('Real Tonight', () {
    test(
      'choose sends the complete context with a version and a key',
      () async {
        final rig = TodayRig();
        final repo = ApiTodayRepository(rig.api);
        final envelope = await repo.choose(
          const SessionContext(
            desiredExperience: DesiredExperience.keepMeHooked,
            currentMood: CurrentMood.down,
            maxRuntimeMinutes: 90,
          ),
        );
        expect(envelope.state, TodayStatus.offered);
        final sent = rig.server.commands('/today/choose').single;
        expect(sent.data, {
          'expected_session_version': 0,
          'context': {
            'current_mood': 'down',
            'desired_experience': 'keep_me_hooked',
            'max_runtime_minutes': 90,
            'heaviness_max': null,
            'avoid_genre_ids': <int>[],
          },
          'continue_after_pause': false,
        });
        expect(sent.headers['Idempotency-Key'], isNotEmpty);
        // The next command carries the version the server returned.
        await repo.accept(envelope.recommendation!.id);
        expect(
          (rig.server.commands('/accept').single.data
              as Map)['expected_session_version'],
          1,
        );
      },
    );

    test(
      'documented conflicts become TodayConflict; malformed is an error',
      () async {
        final rig = TodayRig();
        final repo = ApiTodayRepository(rig.api);
        await repo.today();
        rig.server.version = 7;
        await expectLater(
          repo.choose(
            const SessionContext(desiredExperience: DesiredExperience.relax),
          ),
          throwsA(
            isA<TodayConflict>().having(
              (c) => c.code,
              'code',
              'VERSION_CONFLICT',
            ),
          ),
        );
        rig.server.failStatus = 200;
        rig.server.failCode = 'X';
        await expectLater(repo.today(), throwsA(isA<ApiError>()));
      },
    );

    testWidgets('context first, then exactly one real film with reasons', (
      tester,
    ) async {
      final rig = await start(tester);
      expect(find.text('What do you want from tonight?'), findsOneWidget);
      expect(find.byType(MoviePoster), findsNothing, reason: 'no film yet');
      await pickExciting(tester, time: 'Up to 90 min');
      expect(find.byType(MoviePoster), findsOneWidget);
      expect(find.text('Run Lola Run'), findsOneWidget);
      // The card stays clean: reasons live behind Why this film?.
      expect(
        find.text('81 minutes, within your 90-minute limit.'),
        findsNothing,
      );
      await tapText(tester, 'Why this film?');
      expect(
        find.text('81 minutes, within your 90-minute limit.'),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(10, 10)); // dismiss the sheet
      await tester.pumpAndSettle();
      expect(find.text('Arrival'), findsNothing, reason: 'no runners-up');
      expect(find.text('Watch Tonight'), findsOneWidget);
      expect(find.text('Not feeling it'), findsOneWidget);
      // Viewing history is P5: no Already seen, Never recommend or Mark watched.
      expect(find.text('Already seen'), findsNothing);
      expect(find.byTooltip('More actions'), findsNothing);
      expect(rig.server.commands('/today/choose'), hasLength(1));
    });

    testWidgets('reopening shows the same film and never chooses again', (
      tester,
    ) async {
      final rig = await start(tester);
      await pickExciting(tester);
      await tester.pumpWidget(const SizedBox());
      await start(tester, rig);
      expect(find.text('Run Lola Run'), findsOneWidget);
      expect(rig.server.commands('/today/choose'), hasLength(1));
    });

    testWidgets('Why shows the winner breakdown only', (tester) async {
      await start(tester);
      await pickExciting(tester);
      await tapText(tester, 'Why this film?');
      expect(find.text('How it scored'), findsOneWidget);
      expect(find.text('In your watchlist for 3 months.'), findsWidgets);
      expect(find.text('24.0 of 30'), findsOneWidget);
      expect(find.textContaining('weighted_v1 · weights_v1'), findsOneWidget);
      expect(find.text('Arrival'), findsNothing);
      expect(find.textContaining('%'), findsNothing);
    });

    testWidgets('Watch Tonight records intent once, even on a double tap', (
      tester,
    ) async {
      final rig = await start(tester);
      await pickExciting(tester);
      await tester.tap(find.text('Watch Tonight'));
      await tester.tap(find.text('Watch Tonight'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(rig.server.commands('/accept'), hasLength(1));
      expect(find.text("Tonight's plan"), findsOneWidget);
      expect(find.text('Change my mind'), findsOneWidget);
      expect(find.text('Mark watched'), findsNothing, reason: 'P5');
    });

    for (final (label, wire) in [
      ('Not feeling this one', 'not_tonight'),
      ('Something lighter', 'want_lighter'),
      ('Just give me another', 'not_tonight'),
    ]) {
      testWidgets('reason "$label" sends $wire and shows ONE new film', (
        tester,
      ) async {
        final rig = await start(tester);
        await pickExciting(tester);
        await tapText(tester, 'Not feeling it');
        expect(find.text('Already seen'), findsNothing);
        await tapText(tester, label);
        await tapText(tester, 'Show another');
        final sent = rig.server.commands('/reject').single.data as Map;
        expect(sent['reason'], wire);
        expect(sent['choose_another'], isTrue);
        expect(find.text('Run Lola Run'), findsNothing);
        expect(find.byType(MoviePoster), findsOneWidget);
      });
    }

    testWidgets('Too long and Different genre send their details', (
      tester,
    ) async {
      final rig = await start(tester);
      await pickExciting(tester, time: 'Under 2 hours');
      await tapText(tester, 'Not feeling it');
      await tapText(tester, 'Too long');
      await tapText(tester, 'Up to 90 min');
      await tapText(tester, 'Show another');
      var sent = rig.server.commands('/reject').last.data as Map;
      expect(sent['reason'], 'too_long');
      expect(sent['details'], {'max_runtime_minutes': 90});

      await tapText(tester, 'Not feeling it');
      await tapText(tester, 'Different genre');
      await tapText(tester, 'Thriller');
      await tapText(tester, 'Show another');
      sent = rig.server.commands('/reject').last.data as Map;
      expect(sent['reason'], 'wrong_genre');
      expect(sent['details'], {
        'avoid_genre_ids': [53],
      });
    });

    testWidgets('third pass pauses; Continue once brings exactly one', (
      tester,
    ) async {
      final rig = await start(tester);
      await pickExciting(tester);
      for (var i = 0; i < 3; i++) {
        await tapText(tester, 'Not feeling it');
        await tapText(tester, 'Just give me another');
        await tapText(tester, 'Show another');
      }
      expect(find.byType(MoviePoster), findsNothing);
      expect(find.text('Continue once'), findsOneWidget);
      await tapText(tester, 'Continue once');
      expect(find.byType(MoviePoster), findsOneWidget);
      final last = rig.server.commands('/today/choose').last.data as Map;
      expect(last['continue_after_pause'], isTrue);
      expect(rig.server.rejections, 3, reason: 'Continue once keeps the count');
    });

    testWidgets('Stop for tonight clears the film without choosing', (
      tester,
    ) async {
      final rig = await start(tester);
      await pickExciting(tester);
      await tapText(tester, 'Not feeling it');
      await tapText(tester, 'Not feeling this one');
      await tapText(tester, 'Stop for tonight');
      final sent = rig.server.commands('/reject').single.data as Map;
      expect(sent['choose_another'], isFalse);
      expect(find.byType(MoviePoster), findsNothing);
      expect(rig.server.commands('/today/choose'), hasLength(1));
    });

    testWidgets('no match explains itself and never relaxes the limit', (
      tester,
    ) async {
      final rig = TodayRig();
      rig.server.films.removeWhere((f) => (f['runtime_minutes'] as int) < 90);
      await start(tester, rig);
      await pickExciting(tester, time: 'Up to 90 min');
      expect(find.byType(MoviePoster), findsNothing);
      expect(
        find.textContaining('longer than your time limit'),
        findsOneWidget,
      );
      expect(find.text('Arrival'), findsNothing);
    });

    testWidgets('empty watchlist leads to Add movies, not an error', (
      tester,
    ) async {
      final rig = TodayRig()..server.emptyWatchlist = true;
      await start(tester, rig);
      expect(find.text('Your watchlist is empty'), findsOneWidget);
      expect(find.text('Add movies'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets(
      'Skip sends only the explicit Surprise me intent and returns one film',
      (tester) async {
        final rig = await start(tester);
        // Half-selected values are ignored by Skip.
        await tapText(tester, 'Any length');
        await tapText(tester, 'Up to 90 min');
        await tapText(tester, 'Skip, just pick something');

        final chooses = [
          for (final r in rig.server.requests)
            if (r.method == 'POST' && r.path == '/api/v1/today/choose') r,
        ];
        expect(chooses, hasLength(1));
        final sent = (chooses.single.data as Map)['context'] as Map;
        expect(sent['desired_experience'], 'surprise');
        expect(sent['current_mood'], isNull);
        expect(sent['max_runtime_minutes'], isNull);
        expect(sent['prefer_genre_ids'] ?? [], isEmpty);
        expect(sent['avoid_genre_ids'] ?? [], isEmpty);
        expect(chooses.single.headers['Idempotency-Key'], isNotNull);
        expect(find.byType(MoviePoster), findsOneWidget);
        expect(find.text('Watch Tonight'), findsOneWidget);
      },
    );

    testWidgets('a failed Skip keeps the setup and can be retried', (
      tester,
    ) async {
      final rig = await start(tester);
      rig.server.failStatus = 503;
      await tapText(tester, 'Skip, just pick something');
      expect(find.textContaining("Couldn't reach Cinemé"), findsOneWidget);
      expect(find.byType(MoviePoster), findsNothing);
      expect(find.text('Skip, just pick something'), findsOneWidget);

      rig.server.failStatus = null;
      await tapText(tester, 'Skip, just pick something');
      expect(find.byType(MoviePoster), findsOneWidget);
    });

    testWidgets('a backend failure keeps the context and says so', (
      tester,
    ) async {
      final rig = await start(tester);
      rig.server.failStatus = 503;
      await pickExciting(tester);
      expect(find.textContaining("Couldn't reach Cinemé"), findsOneWidget);
      expect(find.text('What do you want from tonight?'), findsOneWidget);
      rig.server.failStatus = null;
      await tapText(tester, 'Pick my movie');
      expect(find.byType(MoviePoster), findsOneWidget);
    });

    testWidgets('a stale version reloads and explains', (tester) async {
      final rig = await start(tester);
      await pickExciting(tester);
      rig.server.version = 9; // changed on another device
      await tapText(tester, 'Watch Tonight');
      expect(
        find.text("Tonight's choice changed. Showing the latest."),
        findsOneWidget,
      );
    });

    testWidgets('auth failure is an error, never a fake film', (tester) async {
      final rig = TodayRig()
        ..server.failStatus = 401
        ..server.failCode = 'TOKEN_INVALID';
      await start(tester, rig);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byType(MoviePoster), findsNothing);
    });

    testWidgets("account switch reloads Tonight for the new user", (
      tester,
    ) async {
      final rig = await start(tester);
      await pickExciting(tester);
      final reads = rig.server.requests.where((r) => r.path == '/api/v1/today');
      final before = reads.length;
      rig.auth.emit(null);
      await tester.pumpAndSettle();
      rig.auth.emit(bob);
      await tester.pumpAndSettle();
      expect(reads.length, greaterThan(before));
    });

    testWidgets('360x640 at 200% text: card, sheet and Why fit', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await start(tester);
      await pickExciting(tester, time: 'Up to 90 min');
      expect(tester.takeException(), isNull);
      await tapText(tester, 'Why this film?');
      expect(find.text('How it scored'), findsOneWidget);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.text('How it scored'))).pop();
      await tester.pumpAndSettle();
      await tapText(tester, 'Not feeling it');
      expect(find.text('Not this one?'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Already watched, availability and retries', () {
    testWidgets('Already watched records history, then one deliberate choice', (
      tester,
    ) async {
      final rig = await start(tester);
      await pickExciting(tester);
      await tapText(tester, 'Not feeling it');
      expect(find.text('Already watched'), findsOneWidget);
      await tapText(tester, 'Already watched');
      expect(find.textContaining('date unknown'), findsOneWidget);
      await tapText(tester, 'Stop for tonight');
      final sent = rig.server.commands('/reject').single.data as Map;
      expect(sent['reason'], 'already_watched');
      expect(sent['details'], isEmpty, reason: 'no rating, no inferred date');
      expect(
        sent['choose_another'],
        isFalse,
        reason: 'no automatic replacement',
      );
      expect(find.byType(MoviePoster), findsNothing);
      expect(rig.server.commands('/today/choose'), hasLength(1));
    });

    testWidgets('Where to watch shows only the providers TMDB returned', (
      tester,
    ) async {
      final rig = TodayRig();
      rig.server.availability[104] = {
        'region': 'IN',
        'link': null,
        'streaming': [
          {'id': 8, 'name': 'Netflix', 'logo_url': null},
          {'id': 122, 'name': 'JioHotstar', 'logo_url': null},
        ],
        'free': <Object>[],
        'rent': [
          {'id': 2, 'name': 'Apple TV', 'logo_url': null},
        ],
        'buy': <Object>[],
        'fetched_at': null,
        'stale': false,
      };
      await start(tester, rig);
      await pickExciting(tester);
      expect(find.text('Where to watch'), findsOneWidget);
      expect(find.text('Netflix'), findsOneWidget);
      expect(find.text('JioHotstar'), findsOneWidget);
      expect(find.text('Also to rent or buy on Apple TV'), findsOneWidget);
      // Attribution is one tap away, not permanent card text.
      expect(find.text('Streaming data: JustWatch · IN'), findsNothing);
      expect(find.textContaining('JustWatch'), findsNothing);
      expect(find.byKey(const ValueKey('availability-info')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('availability-info')));
      await tester.pumpAndSettle();
      expect(find.text('Streaming data'), findsOneWidget);
      expect(
        find.text(
          'Streaming availability data provided by JustWatch. '
          'Availability may vary by region.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('IN catalogue'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10)); // dismiss
      await tester.pumpAndSettle();
      expect(find.text('Prime Video'), findsNothing);
    });

    testWidgets('no streaming region: a quiet hint, never invented providers', (
      tester,
    ) async {
      final rig = TodayRig();
      rig.server.availability[104] = {
        'region': null,
        'link': null,
        'streaming': <Object>[],
        'free': <Object>[],
        'rent': <Object>[],
        'buy': <Object>[],
        'fetched_at': null,
        'stale': false,
      };
      await start(tester, rig);
      await pickExciting(tester);
      expect(
        find.text('Choose your streaming region to see where to watch'),
        findsOneWidget,
      );
      expect(find.text('Where to watch'), findsNothing);
      expect(find.textContaining('JustWatch'), findsNothing);
      expect(find.text('Netflix'), findsNothing);
      // The pick itself is untouched.
      expect(find.text('Watch Tonight'), findsOneWidget);
      expect(find.byType(MoviePoster), findsOneWidget);

      await tapText(
        tester,
        'Choose your streaming region to see where to watch',
      );
      expect(find.text('Streaming region'), findsOneWidget, reason: 'Profile');
    });

    testWidgets('a region with no providers shows no hint and no heading', (
      tester,
    ) async {
      final rig = TodayRig();
      rig.server.availability[104] = {
        'region': 'IN',
        'link': null,
        'streaming': <Object>[],
        'free': <Object>[],
        'rent': <Object>[],
        'buy': <Object>[],
        'fetched_at': null,
        'stale': false,
      };
      await start(tester, rig);
      await pickExciting(tester);
      expect(find.text('Where to watch'), findsNothing);
      expect(find.textContaining('Choose your streaming region'), findsNothing);
    });

    testWidgets('subscription providers lead; rent/buy is a separate line', (
      tester,
    ) async {
      final rig = TodayRig();
      rig.server.availability[104] = {
        'region': 'IN',
        'link': null,
        'streaming': [
          {'id': 119, 'name': 'Amazon Prime Video', 'logo_url': null},
          {'id': 122, 'name': 'JioHotstar', 'logo_url': null},
        ],
        'free': <Object>[],
        'rent': [
          {'id': 2, 'name': 'Apple TV Store', 'logo_url': null},
        ],
        'buy': [
          {'id': 3, 'name': 'Google Play Movies', 'logo_url': null},
        ],
        'fetched_at': null,
        'stale': false,
      };
      await start(tester, rig);
      await pickExciting(tester);
      final heading = tester.getTopLeft(find.text('Where to watch')).dy;
      final prime = tester.getTopLeft(find.text('Amazon Prime Video')).dy;
      final paid = tester
          .getTopLeft(
            find.text(
              'Also to rent or buy on Apple TV Store, Google Play Movies',
            ),
          )
          .dy;
      expect(heading, lessThan(prime));
      expect(prime, lessThan(paid), reason: 'rent/buy is secondary, below');
      expect(find.text('JioHotstar'), findsOneWidget);
    });

    testWidgets('no providers, unknown region or a failure show nothing', (
      tester,
    ) async {
      final rig = TodayRig();
      rig.server.availability[104] = {
        'region': 'IN',
        'link': null,
        'streaming': <Object>[],
        'free': <Object>[],
        'rent': <Object>[],
        'buy': <Object>[],
        'fetched_at': null,
        'stale': false,
      };
      rig.server.availability[14337] = {
        'region': null,
        'link': null,
        'streaming': <Object>[],
        'free': <Object>[],
        'rent': <Object>[],
        'buy': <Object>[],
        'fetched_at': null,
        'stale': false,
      };
      await start(tester, rig);
      await pickExciting(tester);
      expect(find.text('Where to watch'), findsNothing);
      expect(find.textContaining('JustWatch'), findsNothing);
      // 329865 has no scripted data: the API fails; the card is unaffected.
      rig.server.films.removeAt(0);
      await tapText(tester, 'Not feeling it');
      await tapText(tester, 'Not feeling this one');
      await tapText(tester, 'Show another');
      expect(find.byType(MoviePoster), findsOneWidget);
      expect(find.text('Watch Tonight'), findsOneWidget);
      expect(find.text('Where to watch'), findsNothing);
    });

    test(
      'an ambiguous failure is retried with the same key and replayed',
      () async {
        final rig = TodayRig();
        final repo = ApiTodayRepository(rig.api);
        final pick = await repo.choose(
          const SessionContext(desiredExperience: DesiredExperience.exciting),
        );
        final id = pick.recommendation!.id;
        rig.server.dropResponses = 1;
        await expectLater(
          repo.accept(id),
          throwsA(isA<ApiError>().having((e) => e.status, 'status', isNull)),
        );
        expect(rig.server.processed, 2, reason: 'the accept did commit');
        final retried = await repo.accept(id);
        expect(retried.state, TodayStatus.accepted);
        expect(rig.server.processed, 2, reason: 'replayed, not applied twice');
        expect(rig.server.keys[1], rig.server.keys[2], reason: 'same key');

        // A genuinely new action gets a new key.
        await repo.reject(id, RejectReason.notTonight, chooseAnother: false);
        expect(rig.server.keys.last, isNot(rig.server.keys[2]));
        expect(rig.server.keys.toSet(), hasLength(3));
      },
    );

    test('a definite error settles the key; conflicts stay visible', () async {
      final rig = TodayRig();
      final repo = ApiTodayRepository(rig.api);
      const ctx = SessionContext(desiredExperience: DesiredExperience.relax);
      rig.server.failStatus = 503;
      await expectLater(repo.choose(ctx), throwsA(isA<ApiError>()));
      rig.server.failStatus = 422;
      rig.server.failCode = 'VALIDATION_ERROR';
      await expectLater(repo.choose(ctx), throwsA(isA<ApiError>()));
      rig.server.failStatus = null;
      await repo.choose(ctx);
      final keys = [
        for (final r in rig.server.requests)
          if (r.method == 'POST') r.headers['Idempotency-Key'],
      ];
      expect(keys[0], keys[1], reason: '503 was ambiguous: same key');
      expect(keys[2], isNot(keys[1]), reason: 'after a 4xx, a new key');

      // A server-side key conflict is surfaced, not swallowed or retried.
      rig.server.failStatus = 409;
      rig.server.failCode = 'IDEMPOTENCY_CONFLICT';
      await expectLater(
        repo.choose(ctx),
        throwsA(
          isA<ApiError>().having((e) => e.code, 'code', 'IDEMPOTENCY_CONFLICT'),
        ),
      );
    });

    testWidgets(
      'tapping Watch Tonight again after a lost response accepts once',
      (tester) async {
        final rig = await start(tester);
        await pickExciting(tester);
        rig.server.dropResponses = 1;
        await tapText(tester, 'Watch Tonight');
        expect(find.textContaining("Couldn't reach Cinemé"), findsOneWidget);
        tester
            .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
            .hideCurrentSnackBar();
        await tester.pumpAndSettle();
        await tapText(tester, 'Watch Tonight');
        expect(find.text("Tonight's plan"), findsOneWidget);
        expect(rig.server.processed, 2, reason: 'one choose, one accept');
        final acceptKeys = {
          for (final r in rig.server.commands('/accept'))
            r.headers['Idempotency-Key'],
        };
        expect(acceptKeys, hasLength(1));
      },
    );
  });

  testWidgets('preview Tonight keeps its fakes and P5 actions', (tester) async {
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
    expect(container.read(todayRepositoryProvider), isA<FakeTodayRepository>());
    await pickExciting(tester);
    expect(find.text('Already seen'), findsOneWidget);
  });
}
