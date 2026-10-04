import 'package:cineme/app.dart';
import 'package:cineme/core/widgets/movie_poster.dart';
import 'package:cineme/core/widgets/rating_stars.dart';
import 'package:cineme/features/search/application/search_controller.dart';
import 'package:cineme/features/search/data/search_repository.dart';
import 'package:cineme/features/watchlist/application/watchlist_controller.dart';
import 'package:cineme/preview/preview_catalog.dart';
import 'package:cineme/preview/preview_store.dart';
import 'package:cineme/shared/models/inventory.dart';
import 'package:cineme/shared/models/movie.dart';
import 'package:cineme/shared/models/session_context.dart';
import 'package:cineme/shared/models/today_state.dart';
import 'package:cineme/shared/models/viewing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'nav_finders.dart';

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
  await tester.tap(navTab(label));
  await tester.pumpAndSettle();
}

/// The store's active entries; fake latency needs a pump under fake time.
Future<List<WatchlistEntry>> saved(WidgetTester tester, PreviewStore s) async {
  final page = FakeWatchlistRepository(s).list();
  await tester.pump(const Duration(milliseconds: 1));
  return (await page).items;
}

/// Swipes a watchlist row right by [dx] logical pixels (row is 800 wide).
Future<void> swipe(WidgetTester tester, String title, double dx) async {
  await tester.drag(find.text(title), Offset(dx, 0));
  await tester.pumpAndSettle();
  // The removal request starts when the slide-out ends; let it finish.
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pumpAndSettle();
}

/// The last row/tile ends above the bottom navigation bar once scrolled to
/// the end.
Future<void> expectClearsNav(WidgetTester tester, String lastTitle) async {
  await tester.fling(
    find.byType(Scrollable).last,
    const Offset(0, -20000),
    5000,
  );
  await tester.pumpAndSettle();
  final last = tester.getRect(find.text(lastTitle));
  final nav = tester.getRect(find.byType(FloatingNavBar));
  expect(last.bottom, lessThanOrEqualTo(nav.top), reason: lastTitle);
}

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
  // Posters are the default; these screens are exercised as a list.
  setUp(
    () => SharedPreferences.setMockInitialValues({'watchlist_layout': 'list'}),
  );

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

    test(
      'add: duplicate succeeds, watched conflicts, unreleased saves',
      () async {
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
        final unreleased = await repo.add(previewUnreleased.tmdbId);
        expect(unreleased.alreadyPresent, isFalse);
        expect(unreleased.entry.movie.released, isFalse);
      },
    );

    test('an unreleased film is saved but never picked for Tonight', () async {
      final s = store(watchlist: const [previewUnreleased]);
      final result = await FakeTodayRepository(s).choose(
        const SessionContext(desiredExperience: DesiredExperience.exciting),
      );
      expect(result.recommendation, isNull);
      expect(result.noMatch!.counts, {ExclusionCode.movieUnavailable: 1});
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
        expect(
          find
              .byType(RatingStars)
              .evaluate()
              .map(
                (element) => (element.widget as RatingStars).rating,
              ),
          contains(Rating.four),
        );
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
        await tester.tap(find.text('Choose one'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Exciting').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Pick my movie'));
        await tester.pumpAndSettle();
        expect(find.byType(MoviePoster), findsOneWidget);
        expect(find.text('Watch Tonight'), findsOneWidget);
      },
    );

    testWidgets('swipe below the threshold snaps back and removes nothing', (
      tester,
    ) async {
      await tester.pumpWidget(app(store()));
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');

      final restingAt = tester.getTopLeft(find.text('Run Lola Run'));
      // Mid-swipe the destructive treatment shows; letting go snaps back.
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Run Lola Run')),
      );
      await gesture.moveBy(const Offset(20, 0)); // past the touch slop
      await gesture.moveBy(const Offset(130, 0));
      await tester.pump();
      expect(find.text('Remove'), findsOneWidget);
      // Hold still before letting go, so it is a release, not a fling.
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.moveBy(const Offset(1, 0));
      await gesture.up();
      await tester.pumpAndSettle();

      // Back in place (the leave-behind is clipped to nothing).
      expect(tester.getTopLeft(find.text('Run Lola Run')), restingAt);
      expect(find.textContaining('Removed'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('a full swipe removes without a dialog; Undo restores', (
      tester,
    ) async {
      final s = store();
      await tester.pumpWidget(app(s));
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');

      await swipe(tester, 'Run Lola Run', 600);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Run Lola Run'), findsNothing);
      expect(find.text('Removed “Run Lola Run”.'), findsOneWidget);
      expect(
        (await saved(tester, s)).map((e) => e.movie.title),
        isNot(contains('Run Lola Run')),
        reason: 'removed through the repository, not just hidden',
      );

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('Run Lola Run'), findsOneWidget);
      expect(
        (await saved(tester, s)).map((e) => e.movie.title),
        contains('Run Lola Run'),
      );
    });

    testWidgets('a failed swipe removal restores the row and says so', (
      tester,
    ) async {
      final s = store();
      await tester.pumpWidget(app(s));
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');

      s.simulateErrors = true;
      await swipe(tester, 'Run Lola Run', 600);
      expect(find.text('Run Lola Run'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Run Lola Run')).dx,
        lessThan(200),
        reason: 'row is back in place',
      );
      expect(
        find.textContaining("It's still in your watchlist"),
        findsOneWidget,
      );
    });

    test(
      'a second remove of the same entry is ignored while in flight',
      () async {
        final container = ProviderContainer(
          retry: noAutomaticRetry,
          overrides: previewOverrides(
            PreviewStore(
              watchlist: previewWatchlist,
              latency: const Duration(milliseconds: 20),
            ),
          ),
        );
        addTearDown(container.dispose);
        final entry = (await container.read(watchlistControllerProvider.future))
            .items
            .first;
        final controller = container.read(watchlistControllerProvider.notifier);
        final first = controller.remove(entry);
        final second = controller.remove(entry);
        expect(await second, isFalse);
        expect(await first, isTrue);
      },
    );

    testWidgets('screen readers get a Remove action instead of the swipe', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(app(store()));
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');
      final row = find
          .byWidgetPredicate(
            (w) =>
                w is Semantics && w.properties.customSemanticsActions != null,
          )
          .first;
      expect(
        find.descendant(of: row, matching: find.text('Run Lola Run')),
        findsOneWidget,
      );
      tester.binding.performSemanticsAction(
        SemanticsActionEvent(
          type: SemanticsAction.customAction,
          viewId: tester.view.viewId,
          nodeId: tester.getSemantics(row).id,
          arguments: CustomSemanticsAction.getIdentifier(
            const CustomSemanticsAction(label: 'Remove from watchlist'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Run Lola Run'), findsNothing);
      expect(find.text('Removed “Run Lola Run”.'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('posters are the default layout and titles are centred', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(app(store()));
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');
      expect(find.byType(SliverGrid), findsOneWidget);
      expect(find.byTooltip('Show as list'), findsOneWidget);
      final title = tester.widget<Text>(find.text('Run Lola Run'));
      expect(title.textAlign, TextAlign.center);
      // Centred under its own poster.
      final poster = tester.getRect(find.byType(AspectRatio).first);
      final text = tester.getRect(find.text('Run Lola Run'));
      expect(text.center.dx, closeTo(poster.center.dx, 0.5));
    });

    testWidgets('list/poster toggle switches layout and is remembered', (
      tester,
    ) async {
      await tester.pumpWidget(app(store()));
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');
      expect(find.byType(SliverGrid), findsNothing);
      expect(find.byTooltip('Add movies'), findsOneWidget);

      await tester.tap(find.byTooltip('Show as posters'));
      await tester.pumpAndSettle();
      expect(find.byType(SliverGrid), findsOneWidget);
      expect(find.byTooltip('Add movies'), findsOneWidget);
      // Posters and titles only: no date or runtime.
      expect(find.text('Run Lola Run'), findsOneWidget);
      expect(find.text('1998  ·  81 min'), findsNothing);
      expect(find.textContaining('Added '), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('watchlist_layout'), 'posters');

      // A fresh app start restores the saved layout.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(store()));
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');
      expect(find.byType(SliverGrid), findsOneWidget);

      await tester.tap(find.byTooltip('Show as list'));
      await tester.pumpAndSettle();
      expect(find.byType(SliverGrid), findsNothing);
      expect(prefs.getString('watchlist_layout'), 'list');
    });

    testWidgets('posters: missing artwork shows the placeholder at 2:3', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'watchlist_layout': 'posters'});
      await tester.pumpWidget(app(store(watchlist: fillers(3))));
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');
      final poster = find.byType(MoviePoster).first;
      expect(
        find.descendant(of: poster, matching: find.byType(Image)),
        findsNothing,
      );
      expect(find.text('FILLER 00'), findsOneWidget);
      final size = tester.getSize(poster);
      expect(size.height / size.width, closeTo(1.5, 0.01));
    });

    testWidgets('posters: long-press removes via the same path, with Undo', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'watchlist_layout': 'posters'});
      final s = store();
      await tester.pumpWidget(app(s));
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');

      // No swipe on grid tiles.
      await tester.drag(find.text('Run Lola Run'), const Offset(600, 0));
      await tester.pumpAndSettle();
      expect(find.text('Run Lola Run'), findsOneWidget);
      expect(find.textContaining('Removed'), findsNothing);

      await tester.longPress(find.text('Run Lola Run'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from watchlist'));
      await tester.pumpAndSettle();
      expect(find.text('Run Lola Run'), findsNothing);
      expect(find.text('Removed “Run Lola Run”.'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('Run Lola Run'), findsOneWidget);
    });

    for (final layout in ['list', 'posters']) {
      testWidgets('$layout: the last film scrolls clear of the nav bar', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({'watchlist_layout': layout});
        await tester.pumpWidget(app(store(watchlist: fillers(15))));
        await tester.pumpAndSettle();
        await goTab(tester, 'Watchlist');
        await expectClearsNav(tester, 'Filler 14');
      });

      testWidgets('$layout: 360x640, 200% text and a gesture inset', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(720, 1280);
        tester.view.devicePixelRatio = 2;
        tester.view.padding = const FakeViewPadding(bottom: 48);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        SharedPreferences.setMockInitialValues({'watchlist_layout': layout});

        await tester.pumpWidget(app(store(watchlist: fillers(15))));
        await tester.pumpAndSettle();
        await goTab(tester, 'Watchlist');
        expect(tester.takeException(), isNull);
        await expectClearsNav(tester, 'Filler 14');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('posters: 2 columns when very narrow', (tester) async {
      tester.view.physicalSize = const Size(560, 1280);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'watchlist_layout': 'posters'});
      await tester.pumpWidget(app(store(watchlist: fillers(4))));
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');
      final a = tester.getTopLeft(find.text('Filler 00'));
      final b = tester.getTopLeft(find.text('Filler 01'));
      final c = tester.getTopLeft(find.text('Filler 02'));
      expect(a.dy, b.dy);
      expect(c.dy, greaterThan(a.dy), reason: 'third tile wraps');
      expect(tester.takeException(), isNull);
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
      final list = find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      );
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
        scrollable: list,
      );
      await tester.pumpAndSettle();
      expect(find.text('Filler 19'), findsOneWidget, reason: 'items kept');

      s.simulateErrors = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Filler 39'),
        400,
        scrollable: list,
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

    Future<void> openSearch(WidgetTester tester, String q) async {
      await tester.pumpWidget(app(store()));
      await tester.pumpAndSettle();
      await goTab(tester, 'Watchlist');
      await tester.tap(find.byTooltip('Add movies'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), q);
      await tester.pump(searchDebounce);
      await tester.pumpAndSettle();
    }

    testWidgets('search row: poster | details | Add, centred on the poster', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await openSearch(tester, 'princess');
      final poster = tester.getRect(find.byType(MoviePoster));
      final title = tester.getRect(find.text('The Princess Bride'));
      final add = tester.getRect(find.widgetWithText(OutlinedButton, 'Add'));
      expect(add.left, greaterThan(title.left));
      expect(add.left, greaterThan(poster.right));
      expect(add.center.dy, closeTo(poster.center.dy, 1));
      expect(
        find.text('Add to watchlist'),
        findsNothing,
        reason: 'compact visible label',
      );
      expect(
        find.bySemanticsLabel('Add The Princess Bride to watchlist'),
        findsOneWidget,
      );

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      final saved = tester.getRect(find.text('In watchlist'));
      expect(saved.left, greaterThan(poster.right));
      expect(saved.center.dy, closeTo(poster.center.dy, 1));
      expect(
        find.widgetWithText(OutlinedButton, 'Add'),
        findsNothing,
        reason: 'not primary',
      );
      semantics.dispose();
    });

    testWidgets('search row: Not released yet stays with the details', (
      tester,
    ) async {
      await openSearch(tester, 'untitled');
      final title = tester.getRect(find.textContaining('Untitled Future'));
      final note = tester.getRect(find.text('Not released yet'));
      final add = tester.getRect(find.text('Add'));
      expect(note.left, title.left);
      expect(note.top, greaterThan(title.top));
      expect(add.left, greaterThan(note.right));
    });

    testWidgets('search row: 360x640 at 200% text stacks the action', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await openSearch(tester, 'princess');
      expect(tester.takeException(), isNull);
      final title = tester.getRect(find.text('The Princess Bride'));
      final add = tester.getRect(find.widgetWithText(OutlinedButton, 'Add'));
      expect(add.top, greaterThan(title.bottom), reason: 'below the details');
      expect(add.left, closeTo(title.left, 1));
    });

    testWidgets('search row: 360 wide at normal text keeps one row', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await openSearch(tester, 'princess');
      expect(tester.takeException(), isNull);
      final poster = tester.getRect(find.byType(MoviePoster));
      final add = tester.getRect(find.widgetWithText(OutlinedButton, 'Add'));
      expect(add.center.dy, closeTo(poster.center.dy, 1));
      expect(add.right, lessThanOrEqualTo(360));
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
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(
        find.text('Added “The Princess Bride” to your watchlist.'),
        findsOneWidget,
      );
      expect(find.text('In watchlist'), findsOneWidget);

      await search('amélie');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining("You've already watched “Amélie”"),
        findsOneWidget,
      );

      // Unknown release date: saveable, labelled, never Tonight-eligible.
      await search('untitled');
      expect(find.text('Not released yet'), findsOneWidget);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.text('In watchlist'), findsOneWidget);

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
      await tester.tap(find.text('Choose one'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Exciting').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pick my movie'));
      await tester.pumpAndSettle();
      expect(find.text('Run Lola Run'), findsOneWidget);

      await goTab(tester, 'Watchlist');
      await swipe(tester, 'Run Lola Run', 600);

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
      expect(find.byType(FloatingNavBar), findsNothing);
      expect(find.text('Run Lola Run'), findsNothing);
    });
  });
}
