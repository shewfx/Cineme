import 'dart:convert';
import 'dart:typed_data';

import 'package:cineme/app.dart';
import 'package:cineme/core/config/app_config.dart';
import 'package:cineme/core/network/api_client.dart';
import 'package:cineme/core/widgets/movie_poster.dart';
import 'package:cineme/features/auth/data/account_repository.dart';
import 'package:cineme/features/auth/data/auth_repository.dart';
import 'package:cineme/features/preferences/data/profile_repository.dart';
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
    if (body['expected_session_version'] != version) {
      return _error(409, 'VERSION_CONFLICT');
    }
    if (path == '/api/v1/today/choose') {
      if (body['context'] == null && context == null) {
        return _error(422, 'CONTEXT_REQUIRED');
      }
      final next = body['context'] as Map<String, dynamic>?;
      final changed =
          next != null &&
          context != null &&
          next['desired_experience'] != context!['desired_experience'];
      if (next != null) context = next;
      if (current != null && current!['status'] != 'no_match' && !changed) {
        return _json(200, state);
      }
      if (rejections >= 3 && body['continue_after_pause'] != true && !changed) {
        return _error(409, 'CONTEXT_REVIEW_REQUIRED');
      }
      version++;
      _select();
      return _json(201, state);
    }
    if (path == '/api/v1/today/context') {
      context = body['context'] as Map<String, dynamic>;
      current = null;
      version++;
      return _json(200, state);
    }
    if (path.endsWith('/accept')) {
      current = {...current!, 'status': 'accepted'};
      version++;
      return _json(200, state);
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
      return _json(200, {
        'feedback': {
          'id': 'f',
          'reason': body['reason'],
          'created_at': '2026-10-02T20:00:00Z',
        },
        'viewing': null,
        'today': state,
        'replacement_outcome': outcome,
      });
    }
    return _error(404, 'NOT_FOUND');
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
      todayRepositoryProvider.overrideWithValue(ApiTodayRepository(api)),
    ],
    child: const CinemeApp(),
  );
}

Future<TodayRig> start(WidgetTester tester, [TodayRig? rig]) async {
  rig ??= TodayRig();
  await tester.pumpWidget(rig.app());
  await tester.pumpAndSettle();
  return rig;
}

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

Future<void> pickExciting(WidgetTester tester, {String? time}) async {
  await tapText(tester, 'Exciting');
  if (time != null) await tapText(tester, time);
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
      expect(
        find.text('81 minutes, within your 90-minute limit.'),
        findsOneWidget,
      );
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
