import 'package:cineme/app.dart';
import 'package:cineme/core/widgets/movie_poster.dart';
import 'package:cineme/features/search/application/search_controller.dart';
import 'package:cineme/features/search/data/search_repository.dart';
import 'package:cineme/preview/preview_catalog.dart';
import 'package:cineme/preview/preview_store.dart';
import 'package:cineme/shared/models/inventory.dart';
import 'package:cineme/shared/models/movie.dart';
import 'package:cineme/shared/models/session_context.dart';
import 'package:cineme/shared/models/today_state.dart';
import 'package:cineme/shared/models/viewing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

PreviewStore store({List<Movie> watchlist = previewWatchlist}) =>
    PreviewStore(watchlist: watchlist, latency: Duration.zero);

List<Movie> fillers(int n) => [
  for (var i = 0; i < n; i++)
    Movie(
      tmdbId: 800000 + i,
      title: 'Filler ${i.toString().padLeft(2, '0')}',
      year: 2000,
      runtimeMinutes: 95,
      genres: const [],
    ),
];

Widget app(PreviewStore s) => ProviderScope(
  retry: noAutomaticRetry,
  overrides: previewOverrides(s),
  child: const CinemeApp(),
);

Future<void> goTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

Finder removeButton(String title) => find.byTooltip('Remove $title');

/// Lazy lists only build rows near the viewport; scroll like a user would.
Future<void> reveal(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(
    f,
    300,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.pumpAndSettle();
}

/// Search stub with per-query latency, counting requests.
class _SlowSearch implements MovieSearchRepository {
  final queries = <String>[];

  @override
  Future<SearchPage> search(String query, {int page = 1}) async {
    queries.add(query);
    await Future<void>.delayed(
      Duration(milliseconds: query == 'ar' ? 900 : 50),
    );
    return SearchPage(
      page: 1,
      totalPages: 1,
      results: [
        SearchResult(
          movie: Movie(
            tmdbId: query.length,
            title: 'Result for $query',
            year: 2000,
            runtimeMinutes: null,
            genres: const [],
          ),
          canAdd: true,
        ),
      ],
    );
  }
}

void main() {
  group('Preview store keeps the documented inventory rules', () {
    test('watchlist pages 20 at a time, newest first, then ends', () async {
      final s = store(watchlist: fillers(45));
      final repo = FakeWatchlistRepository(s);
      final p1 = await repo.list();
      final p2 = await repo.list(cursor: p1.nextCursor);
      final p3 = await repo.list(cursor: p2.nextCursor);
      expect([p1.items.length, p2.items.length, p3.items.length], [20, 20, 5]);
      expect(p3.nextCursor, isNull);
      expect(p1.items.first.addedAt.isAfter(p1.items.last.addedAt), isTrue);
    });

    test('removing tonight\'s pick clears it and chooses nothing', () async {
      final s = store();
      final today = FakeTodayRepository(s);
      final watchlist = FakeWatchlistRepository(s);
      final pick = await today.choose(
        const SessionContext(desiredExperience: DesiredExperience.exciting),
      );
      expect(pick.recommendation!.movie.title, 'Run Lola Run');

      final entry = (await watchlist.list()).items.firstWhere(
        (e) => e.movie.tmdbId == 104,
      );
      await watchlist.remove(entry.id);

      expect((await today.today()).state, TodayStatus.ready);
      final records = (await FakeHistoryRepository(s).recommendations()).items;
      expect(records.first.movie!.tmdbId, 104);
      expect(records.first.status, RecommendationStatus.superseded);
    });

    test('Tonight only picks films still in the watchlist', () async {
      final s = store();
      final watchlist = FakeWatchlistRepository(s);
      final groundhog = (await watchlist.list()).items.firstWhere(
        (e) => e.movie.tmdbId == 137,
      );
      await watchlist.remove(groundhog.id);
      final pick = await FakeTodayRepository(s).choose(
        const SessionContext(desiredExperience: DesiredExperience.makeMeLaugh),
      );
      expect(pick.recommendation!.movie.title, 'Airplane!');
    });

    test('add: duplicate succeeds, watched and ineligible conflict', () async {
      final repo = FakeWatchlistRepository(store());
      expect((await repo.add(104)).alreadyPresent, isTrue);
      expect((await repo.add(2493)).alreadyPresent, isFalse);
      await expectLater(
        repo.add(194), // Amélie is seeded as watched
        throwsA(
          isA<InventoryConflict>().having(
            (c) => c.code,
            'code',
            'MOVIE_ALREADY_WATCHED',
          ),
        ),
      );
      await expectLater(
        repo.add(previewUnreleased.tmdbId),
        throwsA(
          isA<InventoryConflict>().having(
            (c) => c.code,
            'code',
            'MOVIE_INELIGIBLE',
          ),
        ),
      );
    });

    test(
      'already watched: unknown date, archives, clears tonight, once',
      () async {
        final s = store();
        final today = FakeTodayRepository(s);
        final history = FakeHistoryRepository(s);
        await today.choose(
          const SessionContext(desiredExperience: DesiredExperience.exciting),
        );

        final first = await history.recordAlreadyWatched(104);
        expect(first.alreadyRecorded, isFalse);
        expect(first.viewing.watchedAt, isNull);
        expect(first.viewing.rating, isNull);
        expect(
          (await FakeWatchlistRepository(
            s,
          ).list()).items.map((e) => e.movie.tmdbId),
          isNot(contains(104)),
        );
        // Logging a past viewing never completes tonight; it clears the pick.
        expect((await today.today()).state, TodayStatus.ready);

        final again = await history.recordAlreadyWatched(104);
        expect(again.alreadyRecorded, isTrue);
        expect(
          (await history.viewings()).items.where((v) => v.movie.tmdbId == 104),
          hasLength(1),
        );
      },
    );

    test('empty watchlist reports empty_watchlist and never picks', () async {
      final today = FakeTodayRepository(store(watchlist: const []));
      expect((await today.today()).state, TodayStatus.emptyWatchlist);
      final r = await today.choose(
        const SessionContext(desiredExperience: DesiredExperience.surprise),
      );
      expect(r.state, TodayStatus.emptyWatchlist);
      expect(r.recommendation, isNull);
    });

    test('search hides runtime until details are known', () async {
      final results = (await FakeSearchRepository(store()).search('ar'))
          .results;
      final arrival = results.firstWhere((r) => r.movie.title == 'Arrival');
      final parasite = results.firstWhere((r) => r.movie.title == 'Parasite');
      expect(arrival.movie.runtimeMinutes, 116); // in watchlist: cached
      expect(parasite.movie.runtimeMinutes, isNull);
    });
  });

  group('Search controller', () {
    testWidgets('debounces, ignores short queries, drops stale responses', (
      tester,
    ) async {
      final slow = _SlowSearch();
      final container = ProviderContainer(
        overrides: [searchRepositoryProvider.overrideWithValue(slow)],
      );
      addTearDown(container.dispose);
      final sub = container.listen(searchControllerProvider, (_, _) {});
      addTearDown(sub.close);
      final c = container.read(searchControllerProvider.notifier);

      c.onQueryChanged('a');
      await tester.pump(const Duration(milliseconds: 400));
      expect(slow.queries, isEmpty, reason: 'below 2 characters');

      c.onQueryChanged('ar');
      await tester.pump(const Duration(milliseconds: 100));
      c.onQueryChanged('arr');
      await tester.pump(const Duration(milliseconds: 100));
      c.onQueryChanged('ar');
      await tester.pump(const Duration(milliseconds: 310));
      expect(slow.queries, ['ar'], reason: 'one request after typing stops');

      // A newer query answers first; the slow older answer must not win.
      c.onQueryChanged('arri');
      await tester.pump(const Duration(milliseconds: 310));
      await tester.pump(const Duration(seconds: 1));
      expect(slow.queries, ['ar', 'arri']);
      final results = container.read(searchControllerProvider).results!.value!;
      expect(results.single.movie.title, 'Result for arri');
    });
  });

  group('Preview screens', () {
    testWidgets(
      'tabs reach inventory, history and profile; Tonight stays one',
      (tester) async {
        await tester.pumpWidget(app(store()));
        await tester.pumpAndSettle();
        expect(find.text('What do you want from tonight?'), findsOneWidget);

        await goTab(tester, 'Watchlist');
        expect(find.text('Run Lola Run'), findsOneWidget);
        expect(find.text('1998  ·  81 min'), findsOneWidget);

        await goTab(tester, 'History');
        expect(find.text('Amélie'), findsOneWidget);
        expect(find.text('Liked'), findsOneWidget);
        expect(find.textContaining('Date unknown'), findsOneWidget);
        await tester.tap(find.text('Recommendations'));
        await tester.pumpAndSettle();
        expect(find.text('For “Comforting”'), findsOneWidget);

        await goTab(tester, 'Profile');
        expect(find.text('UTC'), findsOneWidget);
        await reveal(tester, find.textContaining('uses the TMDB API'));
        expect(
          find.text(
            'This product uses the TMDB API but is not endorsed or certified by TMDB.',
          ),
          findsOneWidget,
        );

        // Tonight still exposes one film, however many are in the watchlist.
        await goTab(tester, 'Tonight');
        await tester.ensureVisible(find.text('Exciting'));
        await tester.tap(find.text('Exciting'));
        await tester.pump();
        await tester.tap(find.text('Pick my movie'));
        await tester.pumpAndSettle();
        expect(find.byType(MoviePoster), findsOneWidget);
        expect(find.text('Watch Tonight'), findsOneWidget);
      },
    );

    testWidgets('remove needs confirmation and is not optimistic', (
      tester,
    ) async {
      final s = store();
      await tester.pumpWidget(app(s));
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');
      await reveal(tester, removeButton('Arrival'));

      await tester.tap(removeButton('Arrival'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Arrival'), findsOneWidget);

      // A failed removal keeps the row and says so.
      s.simulateErrors = true;
      await tester.tap(removeButton('Arrival'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(find.text('Arrival'), findsOneWidget);
      expect(
        find.textContaining("It's still in your watchlist"),
        findsOneWidget,
      );

      s.simulateErrors = false;
      await tester.tap(removeButton('Arrival'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(find.text('Arrival'), findsNothing);
      expect(find.text('Removed “Arrival”.'), findsOneWidget);
    });

    testWidgets('load errors offer Retry; load-more errors keep items', (
      tester,
    ) async {
      final s = store(watchlist: fillers(45))..simulateErrors = true;
      await tester.pumpWidget(app(s));
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Filler 00'), findsNothing);

      s.simulateErrors = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Filler 00'), findsOneWidget);

      // A failed pull-to-refresh keeps the rows and says so.
      s.simulateErrors = true;
      await tester.fling(find.text('Filler 00'), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
      expect(find.text('Filler 00'), findsOneWidget);
      expect(find.textContaining("Couldn't refresh"), findsOneWidget);
      tester
          .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
          .hideCurrentSnackBar();
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text("Couldn't load more."),
        400,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(find.text('Filler 19'), findsOneWidget, reason: 'items kept');

      s.simulateErrors = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Filler 39'),
        400,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Filler 39'), findsOneWidget);
    });

    testWidgets('empty watchlist: Tonight and Watchlist both lead to Add', (
      tester,
    ) async {
      await tester.pumpWidget(app(store(watchlist: const [])));
      await tester.pumpAndSettle();
      expect(find.text('Your watchlist is empty'), findsOneWidget);
      expect(find.text('Pick my movie'), findsNothing);
      await goTab(tester, 'Watchlist');
      expect(find.text('Add movies'), findsOneWidget);
    });

    testWidgets('search adds, records watched and explains each state', (
      tester,
    ) async {
      await tester.pumpWidget(app(store()));
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');
      await tester.tap(find.byTooltip('Add movies'));
      await tester.pumpAndSettle();

      Future<void> search(String q) async {
        await tester.enterText(find.byType(TextField), q);
        await tester.pump(searchDebounce);
        await tester.pumpAndSettle();
      }

      await search('zzz');
      expect(find.text('No films match “zzz”'), findsOneWidget);

      await search('princess');
      await tester.tap(find.text('Add to watchlist'));
      await tester.pumpAndSettle();
      expect(
        find.text('Added “The Princess Bride” to your watchlist.'),
        findsOneWidget,
      );
      expect(find.text('In watchlist'), findsOneWidget);

      await search('amélie');
      await tester.tap(find.text('Add to watchlist'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining("You've already watched “Amélie”"),
        findsOneWidget,
      );

      await search('untitled');
      expect(find.text("Can't be added yet"), findsOneWidget);
      expect(find.text('Add to watchlist'), findsNothing);

      await search('primer');
      await tester.tap(find.text('Already watched'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record'));
      await tester.pumpAndSettle();
      expect(find.text('Recorded “Primer” as watched.'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('The Princess Bride'), findsOneWidget);
      expect(
        find.text('Primer'),
        findsNothing,
        reason: 'archived from watchlist',
      );
      await goTab(tester, 'History');
      expect(find.text('Primer'), findsOneWidget);
    });

    testWidgets('removing tonight\'s pick returns Tonight to context', (
      tester,
    ) async {
      await tester.pumpWidget(app(store()));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Exciting'));
      await tester.tap(find.text('Exciting'));
      await tester.pump();
      await tester.tap(find.text('Pick my movie'));
      await tester.pumpAndSettle();
      expect(find.text('Run Lola Run'), findsOneWidget);

      await goTab(tester, 'Watchlist');
      await reveal(tester, removeButton('Run Lola Run'));
      await tester.tap(removeButton('Run Lola Run'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      await goTab(tester, 'Tonight');
      expect(find.text('Ready for another pick?'), findsOneWidget);
      await goTab(tester, 'History');
      await tester.tap(find.text('Recommendations'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Cleared'), findsOneWidget);
    });

    testWidgets('every tab fits 360x640 at 200% text', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpWidget(app(store()));
      await tester.pumpAndSettle();
      for (final tab in ['Watchlist', 'History', 'Profile', 'Tonight']) {
        await goTab(tester, tab);
        expect(tester.takeException(), isNull, reason: tab);
      }
      await goTab(tester, 'Watchlist');
      await tester.tap(find.byTooltip('Add movies'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'spider');
      await tester.pump(searchDebounce);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'search');
    });

    testWidgets('normal build shows no fake inventory', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(retry: noAutomaticRetry, child: CinemeApp()),
      );
      await tester.pumpAndSettle();
      // No tabs at all without configuration, so no fake inventory either.
      expect(find.text('This build is not configured'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Run Lola Run'), findsNothing);
    });
  });
}
