import 'package:cineme/app.dart';
import 'package:cineme/core/config/app_config.dart';
import 'package:cineme/core/network/api_client.dart';
import 'package:cineme/core/widgets/movie_list_tile.dart';
import 'package:cineme/features/auth/application/auth_controller.dart';
import 'package:cineme/features/auth/data/account_repository.dart';
import 'package:cineme/features/auth/data/auth_repository.dart';
import 'package:cineme/routing/app_router.dart' show authRedirect;
import 'package:cineme/features/preferences/data/profile_repository.dart';
import 'package:cineme/features/search/data/search_repository.dart';
import 'package:cineme/features/today/data/today_repository.dart';
import 'package:cineme/features/watchlist/data/watchlist_repository.dart';
import 'package:cineme/shared/models/inventory.dart';
import 'package:cineme/shared/models/movie.dart';
import 'package:cineme/shared/models/profile.dart';
import 'package:cineme/shared/models/today_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'auth_test.dart' show FakeAuth, alice, bob, config;
import 'nav_finders.dart';

/// The server's view of every account, shared by every "device".
class Server {
  final pending = <String, bool>{};
  final completeCalls = <String, int>{};
  final lists = <String, List<WatchlistEntry>>{};
  int failCompletions = 0;
  int failAdds = 0;
}

const _unavailable = ApiError(
  status: 503,
  code: 'DEPENDENCY_UNAVAILABLE',
  message: 'Try again shortly.',
  retryable: true,
);

class FakeAccount implements AccountRepository {
  FakeAccount(this.auth, this.server);
  final FakeAuth auth;
  final Server server;
  String get _uid => auth.currentUser!.id;

  @override
  Future<void> bootstrap() async {}

  @override
  Future<Profile> me() async => Profile(
    displayName: null,
    timezone: 'UTC',
    preferredGenres: const [],
    blockedGenres: const [],
    defaultMaxRuntimeMinutes: null,
    aiContextEnabled: false,
    blockedMovies: null,
    onboardingComplete: !(server.pending[_uid] ?? false),
  );

  @override
  Future<void> completeOnboarding() async {
    server.completeCalls[_uid] = (server.completeCalls[_uid] ?? 0) + 1;
    if (server.failCompletions > 0) {
      server.failCompletions--;
      throw _unavailable;
    }
    server.pending[_uid] = false;
  }

  @override
  Future<void> setRegion(String? countryCode) async {}
  @override
  Future<List<(String, String)>> regions() async => const [];
  @override
  Future<void> unblock(int tmdbId) async {}
  @override
  Future<void> block(int tmdbId) async {}
}

Movie film(int id, String title) => Movie(
  tmdbId: id,
  title: title,
  year: 2000 + id,
  runtimeMinutes: null,
  genres: const [],
);

final catalog = {for (var i = 1; i <= 7; i++) i: film(i, 'Film $i')};

class FakeWatchlist implements WatchlistRepository {
  FakeWatchlist(this.auth, this.server);
  final FakeAuth auth;
  final Server server;
  List<WatchlistEntry> get _list => server.lists.putIfAbsent(
    auth.currentUser?.id ?? '',
    () => <WatchlistEntry>[],
  );

  @override
  Future<Paged<WatchlistEntry>> list({
    String? cursor,
    WatchlistSort sort = WatchlistSort.addedDesc,
  }) async => Paged(List.of(_list), null);

  @override
  Future<WatchlistAddResult> add(int tmdbId) async {
    if (server.failAdds > 0) {
      server.failAdds--;
      throw _unavailable;
    }
    for (final e in _list) {
      if (e.movie.tmdbId == tmdbId) {
        return WatchlistAddResult(entry: e, alreadyPresent: true);
      }
    }
    final entry = WatchlistEntry(
      id: 'w$tmdbId',
      movie: catalog[tmdbId]!,
      addedAt: DateTime.utc(2026, 10, 8),
    );
    _list.insert(0, entry);
    return WatchlistAddResult(entry: entry, alreadyPresent: false);
  }

  @override
  Future<void> remove(String entryId) async {}
}

class FakeSearch implements MovieSearchRepository {
  @override
  Future<SearchPage> search(String query, {int page = 1}) async => SearchPage(
    page: 1,
    totalPages: 1,
    results: [
      for (final m in catalog.values) SearchResult(movie: m, canAdd: true),
    ],
  );
}

/// Tonight with nothing on the watchlist: the honest, existing empty state.
/// Any other call means onboarding did something it must not.
class FakeToday implements TodayRepository {
  int reads = 0;

  @override
  Future<TodayEnvelope> today() async {
    reads++;
    return const TodayEnvelope.emptyWatchlist();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'Onboarding must not call ${invocation.memberName}',
  );
}

class Rig {
  Rig({AuthUser? signedIn, Server? server})
    : server = server ?? Server(),
      auth = FakeAuth(signedIn) {
    account = FakeAccount(auth, this.server);
    watchlist = FakeWatchlist(auth, this.server);
  }

  final Server server;
  final FakeAuth auth;
  late final FakeAccount account;
  late final FakeWatchlist watchlist;
  final today = FakeToday();

  Widget app() => ProviderScope(
    retry: noAutomaticRetry,
    overrides: [
      appConfigProvider.overrideWithValue(config),
      authRepositoryProvider.overrideWithValue(auth),
      accountRepositoryProvider.overrideWithValue(account),
      profileRepositoryProvider.overrideWithValue(
        AccountProfileRepository(account),
      ),
      watchlistRepositoryProvider.overrideWithValue(watchlist),
      searchRepositoryProvider.overrideWithValue(FakeSearch()),
      todayRepositoryProvider.overrideWithValue(today),
    ],
    child: const CinemeApp(),
  );
}

/// A tall phone so every result row is built.
void tallView(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(400, 3000)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> search(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), 'film');
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

Finder addButton(int id) => find.descendant(
  of: find.ancestor(
    of: find.text('Film $id'),
    matching: find.byType(MovieListTile),
  ),
  matching: find.text('Add'),
);

Future<void> openAddStep(WidgetTester tester) async {
  await tester.tap(find.text('Add movies'));
  await tester.pumpAndSettle();
}

Future<void> add(WidgetTester tester, int id) async {
  await tester.tap(addButton(id));
  await tester.pumpAndSettle();
}

Future<Rig> pendingRig(WidgetTester tester, {Server? server}) async {
  tallView(tester);
  final rig = Rig(signedIn: alice, server: server)
    ..server.pending['alice'] = true;
  await tester.pumpWidget(rig.app());
  await tester.pumpAndSettle();
  return rig;
}

Map<String, dynamic> meJson([Map<String, dynamic> extra = const {}]) => {
  'id': 'u',
  'display_name': null,
  'timezone': 'UTC',
  'country_code': null,
  'region': null,
  'created_at': '2026-10-08T00:00:00Z',
  'preferences': {
    'version': 1,
    'genre_preferences': <String, dynamic>{},
    'blocked_genre_ids': <int>[],
    'default_max_runtime_minutes': null,
    'ai_context_enabled': false,
  },
  ...extra,
};

void main() {
  group('GET /me compatibility', () {
    test('a response without the field is complete (older backend)', () {
      expect(profileFromJson(meJson()).onboardingComplete, isTrue);
    });

    test('null means pending; a timestamp means complete', () {
      final pending = meJson({'onboarding_completed_at': null});
      expect(profileFromJson(pending).onboardingComplete, isFalse);
      final done = meJson({'onboarding_completed_at': '2026-10-08T01:00:00Z'});
      expect(profileFromJson(done).onboardingComplete, isTrue);
    });

    test('a malformed value is a visible error, not a guess', () {
      expect(
        () => profileFromJson(meJson({'onboarding_completed_at': 5})),
        throwsA(isA<ApiError>()),
      );
    });

    test('only onboarding leaves the gate room for the welcome', () {
      expect(authRedirect(AuthGate.onboarding, '/today'), '/onboarding');
      expect(authRedirect(AuthGate.onboarding, '/onboarding'), isNull);
      expect(authRedirect(AuthGate.ready, '/onboarding'), '/today');
      expect(authRedirect(AuthGate.ready, '/today'), isNull);
      expect(authRedirect(AuthGate.signedOut, '/onboarding'), '/sign-in');
    });
  });

  testWidgets('a new account sees the welcome and can add films', (
    tester,
  ) async {
    final rig = await pendingRig(tester);
    expect(find.text('One movie. No scrolling.'), findsOneWidget);
    expect(find.byType(FloatingNavBar), findsNothing);
    await openAddStep(tester);
    expect(
      find.text('Nothing is required. Five is a good start.'),
      findsOneWidget,
    );
    expect(find.text('Already watched'), findsNothing);

    await search(tester);
    await add(tester, 1);
    expect(find.text('1 film added. Five is a good start.'), findsOneWidget);
    await add(tester, 2);
    expect(find.text('2 films added. Five is a good start.'), findsOneWidget);
    expect(rig.server.lists['alice']!.length, 2);
    expect(
      rig.server.completeCalls['alice'],
      isNull,
      reason: 'adding does not complete onboarding',
    );
  });

  testWidgets('five films is a nudge, and Continue then opens Tonight', (
    tester,
  ) async {
    final rig = await pendingRig(tester);
    await openAddStep(tester);
    await search(tester);
    for (var i = 1; i <= 5; i++) {
      await add(tester, i);
    }
    expect(
      find.text(
        "5 films added. That's a good start. You can add more any time.",
      ),
      findsOneWidget,
    );
    expect(
      find.text('Film 6'),
      findsOneWidget,
      reason: 'nothing auto-advances at five',
    );

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(rig.server.completeCalls['alice'], 1);
    expect(find.byType(FloatingNavBar), findsOneWidget);
    expect(find.text('One movie. No scrolling.'), findsNothing);
  });

  testWidgets('Skip completes onboarding; Tonight is the honest empty state', (
    tester,
  ) async {
    final rig = await pendingRig(tester);
    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();

    expect(rig.server.completeCalls['alice'], 1);
    expect(rig.server.pending['alice'], false);
    expect(find.text('Your watchlist is empty'), findsOneWidget);
    expect(find.byType(FloatingNavBar), findsOneWidget);
  });

  testWidgets('Continue with an empty list ends at the empty state too', (
    tester,
  ) async {
    final rig = await pendingRig(tester);
    await openAddStep(tester);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Your watchlist is empty'), findsOneWidget);
    expect(rig.server.lists['alice'], anyOf(isNull, isEmpty));
  });

  testWidgets('Skip from the add step keeps the films already added', (
    tester,
  ) async {
    final rig = await pendingRig(tester);
    await openAddStep(tester);
    await search(tester);
    await add(tester, 3);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(rig.server.completeCalls['alice'], 1);
    expect(rig.server.lists['alice']!.single.movie.tmdbId, 3);
  });

  testWidgets('a failed add stays retryable and the count stays honest', (
    tester,
  ) async {
    final rig = await pendingRig(tester);
    rig.server.failAdds = 1;
    await openAddStep(tester);
    await search(tester);
    await add(tester, 1);
    expect(find.textContaining("Couldn't reach Cinemé"), findsOneWidget);
    expect(
      find.text('Nothing is required. Five is a good start.'),
      findsOneWidget,
    );
    expect(addButton(1), findsOneWidget, reason: 'still offers Add');

    await add(tester, 1);
    expect(find.text('1 film added. Five is a good start.'), findsOneWidget);
    expect(rig.server.lists['alice']!.length, 1);
  });

  testWidgets('a duplicate add never double counts, and films resume', (
    tester,
  ) async {
    final server = Server()
      ..lists['alice'] = [
        WatchlistEntry(
          id: 'w1',
          movie: catalog[1]!,
          addedAt: DateTime.utc(2026, 10, 7),
        ),
      ];
    final rig = await pendingRig(tester, server: server);
    // Films already saved (this or another device): the intro is skipped.
    expect(find.text('One movie. No scrolling.'), findsNothing);
    expect(find.text('1 film added. Five is a good start.'), findsOneWidget);
    await search(tester);
    await add(tester, 1);
    expect(find.text('1 film added. Five is a good start.'), findsOneWidget);
    expect(rig.server.lists['alice']!.length, 1);
  });

  testWidgets('a failed completion keeps the user here and can be retried', (
    tester,
  ) async {
    final rig = await pendingRig(tester);
    rig.server.failCompletions = 1;
    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();
    expect(
      find.text("Couldn't save that. Check your connection and try again."),
      findsOneWidget,
    );
    expect(find.byType(FloatingNavBar), findsNothing);
    expect(rig.server.pending['alice'], true);

    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();
    expect(find.byType(FloatingNavBar), findsOneWidget);
    expect(rig.server.completeCalls['alice'], 2);
  });

  testWidgets('leaving without Skip or Continue does not complete it', (
    tester,
  ) async {
    final server = Server();
    await pendingRig(tester, server: server);
    await openAddStep(tester);
    await search(tester);
    await add(tester, 1);

    // The app closes; the same account opens later (or on another device).
    await tester.pumpWidget(const SizedBox());
    final second = Rig(signedIn: alice, server: server);
    await tester.pumpWidget(second.app());
    await tester.pumpAndSettle();
    expect(server.completeCalls['alice'], isNull);
    expect(server.pending['alice'], true);
    expect(find.byType(FloatingNavBar), findsNothing);
    expect(find.text('1 film added. Five is a good start.'), findsOneWidget);
  });

  testWidgets('back from the add step returns to the welcome only', (
    tester,
  ) async {
    final rig = await pendingRig(tester);
    await openAddStep(tester);
    expect(find.text('Add films you want to watch'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('One movie. No scrolling.'), findsOneWidget);
    expect(rig.server.completeCalls['alice'], isNull);
    expect(find.byType(FloatingNavBar), findsNothing);
  });

  testWidgets('an existing or older-backend profile never sees onboarding', (
    tester,
  ) async {
    tallView(tester);
    final rig = Rig(signedIn: alice); // the server says complete
    await tester.pumpWidget(rig.app());
    await tester.pumpAndSettle();
    expect(find.text('One movie. No scrolling.'), findsNothing);
    expect(find.byType(FloatingNavBar), findsOneWidget);
  });

  testWidgets('account switch re-evaluates per user; Sign out is reachable', (
    tester,
  ) async {
    tallView(tester);
    final rig = Rig(signedIn: alice)..server.pending['bob'] = true;
    await tester.pumpWidget(rig.app());
    await tester.pumpAndSettle();
    expect(find.byType(FloatingNavBar), findsOneWidget);

    rig.auth.emit(bob);
    await tester.pumpAndSettle();
    expect(find.text('One movie. No scrolling.'), findsOneWidget);

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(rig.auth.signOuts, 1);
  });

  testWidgets('both steps hold at 200% text on a small phone', (tester) async {
    tester.view
      ..physicalSize = const Size(360, 640)
      ..devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearAllTestValues();
    });
    final rig = Rig(signedIn: alice)..server.pending['alice'] = true;
    await tester.pumpWidget(rig.app());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await openAddStep(tester);
    await search(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
  });
}
