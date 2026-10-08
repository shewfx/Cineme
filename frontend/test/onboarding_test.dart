import 'dart:async';

import 'package:cineme/app.dart';
import 'package:cineme/core/config/app_config.dart';
import 'package:cineme/core/network/api_client.dart';
import 'package:cineme/core/widgets/movie_list_tile.dart';
import 'package:cineme/core/widgets/selector_field.dart';
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
import 'package:cineme/shared/models/series.dart';
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
  int addCalls = 0;

  /// When set, adds wait for it (to hold a request in flight).
  Completer<void>? gate;
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
  Future<void> setTonightMedia(TonightMedia media) async {}
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
  Future<Paged<WatchlistItem>> items({
    String? cursor,
    WatchlistSort sort = WatchlistSort.addedDesc,
    WatchlistMedia media = WatchlistMedia.all,
  }) async {
    if (media == WatchlistMedia.shows) return const Paged([], null);
    final page = await list(cursor: cursor, sort: sort);
    return Paged([for (final e in page.items) MovieItem(e)], page.nextCursor);
  }

  @override
  Future<WatchlistAddResult> add(int tmdbId) async {
    server.addCalls++;
    await server.gate?.future;
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
  /// Films per list, in order; null makes that list's request fail.
  final lists = <DiscoveryList, List<int>?>{
    DiscoveryList.trending: [1, 2, 3, 4],
    DiscoveryList.popularMonth: [5, 6],
    DiscoveryList.popularYear: [6, 7, 1],
  };
  List<int>? get trendingIds => lists[DiscoveryList.trending];
  set trendingIds(List<int>? ids) => lists[DiscoveryList.trending] = ids;
  Set<int> onWatchlist = {};
  int trendingCalls = 0;
  final requested = <DiscoveryList>[];

  @override
  Future<DiscoveryPage> discover(DiscoveryList list) async {
    requested.add(list);
    if (list == DiscoveryList.trending) trendingCalls++;
    final ids = lists[list];
    if (ids == null) throw _unavailable;
    return DiscoveryPage(
      results: [
        for (final i in ids) SearchResult(movie: catalog[i]!, canAdd: true),
      ],
      inWatchlist: onWatchlist,
    );
  }

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
  final searchRepo = FakeSearch();

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
      searchRepositoryProvider.overrideWithValue(searchRepo),
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

/// Opens the Browse dropdown and picks [label].
Future<void> chooseList(WidgetTester tester, String label) async {
  await tester.tap(find.byType(SelectorField));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(of: find.byType(ListTile), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

Finder trendingAdd(int id) => find.descendant(
  of: find.byKey(ValueKey('discover-$id')),
  matching: find.text('Add'),
);

Finder inCell(int id, String text) => find.descendant(
  of: find.byKey(ValueKey('discover-$id')),
  matching: find.text(text),
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
    // Already on the list, so it reads Added and offers no second submit.
    expect(inCell(1, 'Added'), findsOneWidget);
    await search(tester);
    expect(addButton(1), findsNothing);
    expect(rig.server.addCalls, 0);
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

  group('trending this week', () {
    testWidgets('an empty query shows posters with titles and years', (
      tester,
    ) async {
      final rig = await pendingRig(tester);
      await openAddStep(tester);
      expect(find.text('Trending this week'), findsOneWidget);
      expect(
        find.byType(TextField),
        findsOneWidget,
        reason: 'search stays on top',
      );
      for (var i = 1; i <= 4; i++) {
        expect(inCell(i, 'Film $i'), findsOneWidget);
        expect(inCell(i, '${2000 + i}'), findsOneWidget);
        expect(trendingAdd(i), findsOneWidget);
      }
      expect(rig.searchRepo.trendingCalls, 1);
      // Two columns on a narrow phone (400 px wide here).
      Offset at(int i) =>
          tester.getTopLeft(find.byKey(ValueKey('discover-$i')));
      expect(at(2).dy, at(1).dy);
      expect(at(2).dx, greaterThan(at(1).dx));
      expect(at(3).dy, greaterThan(at(1).dy));
      expect(at(3).dx, at(1).dx);
    });

    testWidgets('wider screens fit more columns', (tester) async {
      tester.view
        ..physicalSize = const Size(1200, 3000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rig = Rig(signedIn: alice)..server.pending['alice'] = true;
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await openAddStep(tester);
      final ys = {
        for (var i = 1; i <= 4; i++)
          tester.getTopLeft(find.byKey(ValueKey('discover-$i'))).dy,
      };
      expect(ys.length, 1, reason: 'four films share one row at 1200 px');
    });

    testWidgets('Add shows Added, counts, and cannot be submitted twice', (
      tester,
    ) async {
      final rig = await pendingRig(tester);
      await openAddStep(tester);
      rig.server.gate = Completer<void>();
      await tester.tap(trendingAdd(1));
      await tester.tap(trendingAdd(1)); // same frame: ignored
      rig.server.gate!.complete();
      await tester.pumpAndSettle();

      expect(rig.server.addCalls, 1);
      expect(inCell(1, 'Added'), findsOneWidget);
      expect(trendingAdd(1), findsNothing);
      expect(find.text('1 film added. Five is a good start.'), findsOneWidget);
      expect(find.textContaining("Couldn't reach"), findsNothing);
      expect(rig.server.lists['alice']!.length, 1);
    });

    testWidgets('a failed trending add stays retryable', (tester) async {
      final rig = await pendingRig(tester);
      rig.server.failAdds = 1;
      await openAddStep(tester);
      await tester.tap(trendingAdd(2));
      await tester.pumpAndSettle();
      expect(find.textContaining("Couldn't reach Cinemé"), findsOneWidget);
      expect(inCell(2, 'Added'), findsNothing);
      await tester.tap(trendingAdd(2));
      await tester.pumpAndSettle();
      expect(inCell(2, 'Added'), findsOneWidget);
      expect(rig.server.lists['alice']!.length, 1);
    });

    testWidgets('selection is shared between trending and search', (
      tester,
    ) async {
      final rig = await pendingRig(tester);
      await openAddStep(tester);
      await tester.tap(trendingAdd(1));
      await tester.pumpAndSettle();

      await search(tester);
      expect(find.text('Trending this week'), findsNothing);
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('Film 1'),
            matching: find.byType(MovieListTile),
          ),
          matching: find.text('Added'),
        ),
        findsOneWidget,
        reason: 'search shows what trending added',
      );
      await add(tester, 5); // added from search

      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(find.text('Trending this week'), findsOneWidget);
      expect(inCell(1, 'Added'), findsOneWidget);
      expect(trendingAdd(2), findsOneWidget);
      expect(find.text('2 films added. Five is a good start.'), findsOneWidget);
      expect(rig.server.lists['alice']!.length, 2);
    });

    testWidgets('films the server already lists read as Added', (tester) async {
      tallView(tester);
      final rig = Rig(signedIn: alice)..server.pending['alice'] = true;
      rig.searchRepo.onWatchlist = {3};
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await openAddStep(tester);
      expect(inCell(3, 'Added'), findsOneWidget);
      expect(trendingAdd(3), findsNothing);
    });

    testWidgets('failure offers Retry; search and Continue still work', (
      tester,
    ) async {
      final rig = await pendingRig(tester);
      rig.searchRepo.trendingIds = null;
      await openAddStep(tester);
      expect(find.textContaining("Couldn't load this list"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);

      // Search is unaffected by the failure.
      await search(tester);
      await add(tester, 1);
      expect(find.text('1 film added. Five is a good start.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      rig.searchRepo.trendingIds = [1, 2];
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.textContaining("Couldn't load this list"), findsNothing);
      expect(inCell(1, 'Added'), findsOneWidget);
      expect(trendingAdd(2), findsOneWidget);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(rig.server.completeCalls['alice'], 1);
    });

    testWidgets('an empty trending list says so and Skip still works', (
      tester,
    ) async {
      final rig = await pendingRig(tester);
      rig.searchRepo.trendingIds = [];
      await openAddStep(tester);
      expect(
        find.textContaining('Nothing is trending right now'),
        findsOneWidget,
      );
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(find.text('Your watchlist is empty'), findsOneWidget);
    });

    testWidgets('trending does not appear on Tonight', (tester) async {
      final rig = await pendingRig(tester);
      await openAddStep(tester);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Trending this week'), findsNothing);
      expect(find.text('Your watchlist is empty'), findsOneWidget);
      expect(rig.server.lists['alice'], anyOf(isNull, isEmpty));
    });
  });

  group('Watchlist add screen discovery', () {
    /// An onboarded account on the add screen (Tonight's empty state leads
    /// there), with nothing typed.
    Future<Rig> addScreen(WidgetTester tester) async {
      tallView(tester);
      final rig = Rig(signedIn: alice);
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add movies'));
      await tester.pumpAndSettle();
      return rig;
    }

    testWidgets('one dropdown, defaulting to Trending this week', (
      tester,
    ) async {
      final rig = await addScreen(tester);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(SelectorField), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      expect(find.text('Trending this week'), findsOneWidget);
      expect(find.text('Popular releases this month'), findsNothing);
      // The three options live in the dropdown, the current one checked.
      await tester.tap(find.byType(SelectorField));
      await tester.pumpAndSettle();
      for (final label in [
        'Trending this week',
        'Popular releases this month',
        'Popular releases this year',
      ]) {
        expect(
          find.descendant(
            of: find.byType(ListTile),
            matching: find.text(label),
          ),
          findsOneWidget,
        );
      }
      expect(find.byIcon(Icons.check), findsOneWidget);
      await tester.tapAt(const Offset(10, 10)); // dismiss without choosing
      await tester.pumpAndSettle();
      expect(find.text('Trending this week'), findsOneWidget);
      expect(
        find.text('What people are watching worldwide this week.'),
        findsOneWidget,
      );
      expect(inCell(1, 'Film 1'), findsOneWidget);
      expect(rig.searchRepo.requested, [DiscoveryList.trending]);
    });

    testWidgets('month and year are popular releases with a clear subtitle', (
      tester,
    ) async {
      final rig = await addScreen(tester);
      await chooseList(tester, 'Popular releases this month');
      expect(
        find.text('Released this month, up to today, by current popularity.'),
        findsOneWidget,
      );
      expect(inCell(5, 'Film 5'), findsOneWidget);
      expect(inCell(1, 'Film 1'), findsNothing);
      expect(
        find.textContaining('rending'),
        findsNothing,
        reason: 'month is not trending',
      );

      await chooseList(tester, 'Popular releases this year');
      expect(
        find.text('Released this year, up to today, by current popularity.'),
        findsOneWidget,
      );
      expect(inCell(7, 'Film 7'), findsOneWidget);
      expect(rig.searchRepo.requested, [
        DiscoveryList.trending,
        DiscoveryList.popularMonth,
        DiscoveryList.popularYear,
      ]);
    });

    testWidgets('typing searches; clearing restores the chosen list', (
      tester,
    ) async {
      await addScreen(tester);
      await chooseList(tester, 'Popular releases this year');
      await search(tester);
      expect(find.text('Popular releases this year'), findsNothing);
      expect(find.text('Film 2'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(find.text('Popular releases this year'), findsOneWidget);
      expect(inCell(7, 'Film 7'), findsOneWidget);
      expect(
        find.text('Released this year, up to today, by current popularity.'),
        findsOneWidget,
      );
    });

    testWidgets('membership stays in sync between discovery and search', (
      tester,
    ) async {
      final rig = await addScreen(tester);
      await chooseList(tester, 'Popular releases this year');
      await tester.tap(trendingAdd(6));
      await tester.pumpAndSettle();
      expect(inCell(6, 'Added'), findsOneWidget);

      await search(tester);
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('Film 6'),
            matching: find.byType(MovieListTile),
          ),
          matching: find.text('In watchlist'),
        ),
        findsOneWidget,
      );
      await add(tester, 2); // added from search
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await chooseList(tester, 'Trending this week');
      expect(
        inCell(2, 'Added'),
        findsOneWidget,
        reason: 'search add shows here',
      );
      expect(inCell(1, 'Add'), findsOneWidget);
      expect(rig.server.lists['alice']!.length, 2);
    });

    testWidgets('a failed list offers Retry and leaves the others usable', (
      tester,
    ) async {
      final rig = await addScreen(tester);
      rig.searchRepo.lists[DiscoveryList.popularMonth] = null;
      await chooseList(tester, 'Popular releases this month');
      expect(find.textContaining("Couldn't load this list"), findsOneWidget);
      await chooseList(tester, 'Trending this week');
      expect(inCell(1, 'Film 1'), findsOneWidget);

      rig.searchRepo.lists[DiscoveryList.popularMonth] = [5];
      await chooseList(tester, 'Popular releases this month');
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(inCell(5, 'Film 5'), findsOneWidget);
    });

    testWidgets('the dropdown holds at 320 px and 200% text', (tester) async {
      final rig = await addScreen(tester);
      addTearDown(() {
        tester.view.reset();
        tester.platformDispatcher.clearAllTestValues();
      });
      tester.view
        ..physicalSize = const Size(320, 640)
        ..devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(rig.searchRepo.requested, isNotEmpty);
      await chooseList(tester, 'Popular releases this month');
      expect(tester.takeException(), isNull);
      expect(find.byType(SelectorField), findsOneWidget);
      expect(
        find.text('Released this month, up to today, by current popularity.'),
        findsOneWidget,
      );
    });

    testWidgets('an empty popular list says so', (tester) async {
      final rig = await addScreen(tester);
      rig.searchRepo.lists[DiscoveryList.popularYear] = [];
      await chooseList(tester, 'Popular releases this year');
      expect(
        find.textContaining('No popular releases yet for this period'),
        findsOneWidget,
      );
    });

    testWidgets('onboarding keeps weekly trending only', (tester) async {
      await pendingRig(tester);
      await openAddStep(tester);
      expect(find.text('Trending this week'), findsOneWidget);
      expect(find.text('Popular releases this month'), findsNothing);
      expect(find.text('Popular releases this year'), findsNothing);
    });
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
