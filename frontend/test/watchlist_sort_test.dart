import 'package:cineme/app.dart';
import 'package:cineme/core/widgets/movie_list_tile.dart';
import 'package:cineme/core/widgets/movie_poster.dart';
import 'package:cineme/features/today/presentation/today_intro.dart';
import 'package:cineme/features/watchlist/data/watchlist_repository.dart';
import 'package:cineme/preview/preview_store.dart';
import 'package:cineme/shared/models/inventory.dart';
import 'package:cineme/shared/models/movie.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'real_inventory_test.dart' show Rig;
import 'nav_finders.dart';

Movie film(int id, String title, int? year, int? runtime) => Movie(
  tmdbId: id,
  title: title,
  year: year,
  runtimeMinutes: runtime,
  genres: const [],
);

/// Newest added first. The same data as the backend's sort tests.
final films = [
  film(1, 'Foxtrot', 2024, 90),
  film(2, 'Echo', 1985, 150),
  film(3, 'delta', 2010, null),
  film(4, 'Charlie', null, null),
  film(5, 'alpha', 2010, 90),
  film(6, 'Bravo', 1999, 120),
];

/// Unknown year/runtime last in both directions; ties by title A-Z.
const expected = {
  WatchlistSort.addedDesc: [
    'Foxtrot',
    'Echo',
    'delta',
    'Charlie',
    'alpha',
    'Bravo',
  ],
  WatchlistSort.addedAsc: [
    'Bravo',
    'alpha',
    'Charlie',
    'delta',
    'Echo',
    'Foxtrot',
  ],
  WatchlistSort.titleAsc: [
    'alpha',
    'Bravo',
    'Charlie',
    'delta',
    'Echo',
    'Foxtrot',
  ],
  WatchlistSort.titleDesc: [
    'Foxtrot',
    'Echo',
    'delta',
    'Charlie',
    'Bravo',
    'alpha',
  ],
  WatchlistSort.yearDesc: [
    'Foxtrot',
    'alpha',
    'delta',
    'Bravo',
    'Echo',
    'Charlie',
  ],
  WatchlistSort.yearAsc: [
    'Echo',
    'Bravo',
    'alpha',
    'delta',
    'Foxtrot',
    'Charlie',
  ],
  WatchlistSort.runtimeAsc: [
    'alpha',
    'Foxtrot',
    'Bravo',
    'Echo',
    'Charlie',
    'delta',
  ],
  WatchlistSort.runtimeDesc: [
    'Echo',
    'Bravo',
    'alpha',
    'Foxtrot',
    'Charlie',
    'delta',
  ],
};

PreviewStore store([List<Movie>? inventory]) =>
    PreviewStore(watchlist: inventory ?? films, latency: Duration.zero);

Widget app(PreviewStore s) => ProviderScope(
  retry: noAutomaticRetry,
  overrides: [
    ...previewOverrides(s),
    tonightIntroDurationProvider.overrideWithValue(Duration.zero),
  ],
  child: const CinemeApp(),
);

/// A tall window so every row is built (lists build lazily); pass `tall:
/// false` to keep a size the test set itself.
Future<void> openWatchlist(
  WidgetTester tester,
  PreviewStore s, {
  bool tall = true,
}) async {
  if (tall) tallWindow(tester);
  await tester.pumpWidget(app(s));
  await tester.pumpAndSettle();
  await tester.tap(navTab('Watchlist'));
  await tester.pumpAndSettle();
}

void tallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> chooseSort(WidgetTester tester, WatchlistSort sort) async {
  await tester.tap(find.byTooltip('Sort watchlist'));
  await tester.pumpAndSettle();
  final option = find.descendant(
    of: find.byType(BottomSheet),
    matching: find.text(sort.label),
  );
  if (option.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      option,
      80,
      scrollable: find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(Scrollable),
      ),
    );
  }
  await tester.ensureVisible(option);
  await tester.pumpAndSettle();
  await tester.tap(option);
  await tester.pumpAndSettle();
}

/// Titles in reading order (top to bottom, then left to right), in either
/// layout.
List<String> shown(WidgetTester tester, Iterable<String> candidates) {
  final found = <(Offset, String)>[];
  for (final title in candidates) {
    for (final e in find.text(title).evaluate()) {
      found.add((
        tester.getTopLeft(find.byElementPredicate((x) => x == e)),
        title,
      ));
    }
  }
  found.sort((a, b) {
    final dy = a.$1.dy.round().compareTo(b.$1.dy.round());
    return dy != 0 ? dy : a.$1.dx.compareTo(b.$1.dx);
  });
  return [for (final (_, t) in found) t];
}

/// The store's active entries; fake latency needs a pump under fake time.
Future<List<WatchlistEntry>> saved(WidgetTester tester, PreviewStore s) async {
  final page = FakeWatchlistRepository(s).list();
  await tester.pump(const Duration(milliseconds: 1));
  return (await page).items;
}

List<String> titlesOf(Iterable<WatchlistEntry> entries) => [
  for (final e in entries) e.movie.title,
];

void main() {
  // Posters are the default; these screens are exercised as a list.
  setUp(
    () => SharedPreferences.setMockInitialValues({'watchlist_layout': 'list'}),
  );

  group('Preview store sort follows the server rules', () {
    for (final sort in WatchlistSort.values) {
      test('${sort.apiValue}: ${sort.label}', () async {
        final page = await FakeWatchlistRepository(store()).list(sort: sort);
        expect(titlesOf(page.items), expected[sort]);
      });
    }

    test(
      'pages stay in order across boundaries with ties and unknowns',
      () async {
        final many = [
          for (var i = 0; i < 45; i++)
            film(
              100 + i,
              'Film ${(i * 7 % 45).toString().padLeft(2, '0')}',
              i % 5 == 0
                  ? null
                  : 1980 + i % 6, // many equal years, some unknown
              i % 4 == 0 ? null : 80 + i % 3 * 10,
            ),
        ];
        for (final sort in WatchlistSort.values) {
          final repo = FakeWatchlistRepository(store(many));
          final all = <String>[];
          String? cursor;
          var pages = 0;
          do {
            final page = await repo.list(cursor: cursor, sort: sort);
            all.addAll(titlesOf(page.items));
            cursor = page.nextCursor;
            pages++;
          } while (cursor != null);
          expect(pages, 3, reason: sort.apiValue);
          expect(
            all.toSet(),
            hasLength(45),
            reason: '${sort.apiValue}: no repeats',
          );
          final whole = await repo.list(sort: sort);
          expect(all.take(20), titlesOf(whole.items), reason: sort.apiValue);
        }
      },
    );
  });

  group('Real repository', () {
    test('sends the sort and keeps it for every page', () async {
      final rig = Rig();
      final repo = ApiWatchlistRepository(rig.api);
      await repo.list(sort: WatchlistSort.titleDesc);
      await repo.list(sort: WatchlistSort.titleDesc, cursor: 'abc');
      await repo.list();
      final gets = [
        for (final r in rig.server.requests)
          if (r.method == 'GET' && r.path == '/api/v1/watchlist') r,
      ];
      expect(gets[0].queryParameters['sort'], 'title_desc');
      expect(gets[1].queryParameters['sort'], 'title_desc');
      expect(gets[1].queryParameters['cursor'], 'abc');
      expect(gets[2].queryParameters['sort'], 'added_desc');
    });
  });

  group('Watchlist sort control', () {
    testWidgets('sits in the header beside the layout toggle and Add', (
      tester,
    ) async {
      await openWatchlist(tester, store());
      final sort = tester.getRect(find.byTooltip('Sort watchlist'));
      final layout = tester.getRect(find.byTooltip('Show as posters'));
      final add = tester.getRect(find.byTooltip('Add movies'));
      expect(sort.right, lessThanOrEqualTo(layout.left + 1));
      expect(layout.right, lessThanOrEqualTo(add.left + 1));
      expect(sort.center.dy, closeTo(add.center.dy, 1));
      expect(
        shown(tester, films.map((f) => f.title)),
        expected[WatchlistSort.addedDesc],
      );
    });

    testWidgets('the sheet lists every mode and checks the current one', (
      tester,
    ) async {
      await openWatchlist(tester, store());
      await tester.tap(find.byTooltip('Sort watchlist'));
      await tester.pumpAndSettle();

      expect(find.text('Sort by'), findsOneWidget);
      for (final sort in WatchlistSort.values) {
        final option = find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(sort.label),
        );
        if (option.evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            option,
            80,
            scrollable: find.descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(Scrollable),
            ),
          );
        }
        expect(option, findsOneWidget, reason: sort.label);
      }
      expect(find.byIcon(Icons.check), findsOneWidget);
      final current = find.ancestor(
        of: find.text('Recently added'),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(of: current, matching: find.byIcon(Icons.check)),
        findsOneWidget,
      );
    });

    for (final sort in WatchlistSort.values) {
      testWidgets('${sort.label} orders the list', (tester) async {
        await openWatchlist(tester, store());
        await chooseSort(tester, sort);
        expect(
          shown(tester, films.map((f) => f.title)),
          expected[sort],
          reason: sort.apiValue,
        );
        // The sheet closed, and reopening checks the new choice.
        await tester.tap(find.byTooltip('Sort watchlist'));
        await tester.pumpAndSettle();
        final current = find.ancestor(
          of: find
              .descendant(
                of: find.byType(BottomSheet),
                matching: find.text(sort.label),
              )
              .first,
          matching: find.byType(ListTile),
        );
        expect(
          find.descendant(of: current, matching: find.byIcon(Icons.check)),
          findsOneWidget,
        );
      });
    }

    testWidgets('the choice is saved on this device and restored', (
      tester,
    ) async {
      await openWatchlist(tester, store());
      await chooseSort(tester, WatchlistSort.runtimeDesc);
      expect(
        (await SharedPreferences.getInstance()).getString('watchlist_sort'),
        'runtime_desc',
      );

      // A new launch: the saved order is what the list shows.
      await tester.pumpWidget(const SizedBox());
      SharedPreferences.setMockInitialValues({
        'watchlist_sort': 'runtime_desc',
      });
      await openWatchlist(tester, store());
      expect(
        shown(tester, films.map((f) => f.title)),
        expected[WatchlistSort.runtimeDesc],
      );
    });

    testWidgets('an unknown saved value falls back to Recently added', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'watchlist_sort': 'bogus'});
      await openWatchlist(tester, store());
      expect(
        shown(tester, films.map((f) => f.title)),
        expected[WatchlistSort.addedDesc],
      );
    });

    testWidgets('list and posters show the same order, and keep the sort', (
      tester,
    ) async {
      await openWatchlist(tester, store());
      await chooseSort(tester, WatchlistSort.yearAsc);
      final inList = shown(tester, films.map((f) => f.title));
      expect(find.byType(MovieListTile), findsNWidgets(films.length));
      expect(inList, expected[WatchlistSort.yearAsc]);

      await tester.tap(find.byTooltip('Show as posters'));
      await tester.pumpAndSettle();
      expect(find.byType(MovieListTile), findsNothing);
      expect(find.byType(MoviePoster), findsNWidgets(films.length));
      expect(shown(tester, films.map((f) => f.title)), inList);

      // Changing the sort while in posters, then back to the list.
      await chooseSort(tester, WatchlistSort.titleDesc);
      expect(
        shown(tester, films.map((f) => f.title)),
        expected[WatchlistSort.titleDesc],
      );
      await tester.tap(find.byTooltip('Show as list'));
      await tester.pumpAndSettle();
      expect(
        shown(tester, films.map((f) => f.title)),
        expected[WatchlistSort.titleDesc],
      );
      expect(
        (await SharedPreferences.getInstance()).getString('watchlist_sort'),
        'title_desc',
      );
      expect(
        (await SharedPreferences.getInstance()).getString('watchlist_layout'),
        'list',
      );
    });

    testWidgets('unknown year and runtime go last, in both directions', (
      tester,
    ) async {
      await openWatchlist(tester, store());
      for (final sort in [WatchlistSort.yearAsc, WatchlistSort.yearDesc]) {
        await chooseSort(tester, sort);
        expect(shown(tester, films.map((f) => f.title)).last, 'Charlie');
      }
      for (final sort in [
        WatchlistSort.runtimeAsc,
        WatchlistSort.runtimeDesc,
      ]) {
        await chooseSort(tester, sort);
        final order = shown(tester, films.map((f) => f.title));
        expect(order.sublist(4), ['Charlie', 'delta']);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('pagination under a sort: all 45 films, in order, once each', (
      tester,
    ) async {
      final many = [
        for (var i = 0; i < 45; i++)
          film(100 + i, 'Film ${i.toString().padLeft(2, '0')}', 2000, 100),
      ];
      await openWatchlist(tester, store(many), tall: false);
      await chooseSort(tester, WatchlistSort.titleDesc);

      expect(
        find.text('Film 44'),
        findsOneWidget,
        reason: 'Z-A starts at the end',
      );
      // Scroll down like a user, noting each film the first time it appears.
      final names = [
        for (var i = 44; i >= 0; i--) 'Film ${i.toString().padLeft(2, '0')}',
      ];
      final order = <String>[];
      for (var step = 0; step < 120 && order.length < names.length; step++) {
        for (final name in shown(tester, names)) {
          if (!order.contains(name)) order.add(name);
        }
        await tester.drag(find.byType(Scrollable).last, const Offset(0, -300));
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pumpAndSettle();
      }
      // Every film once, strictly Z to A, across both page boundaries
      // (after 20 and after 40 films).
      expect(order, names);
    });

    testWidgets('sorting changes neither membership nor tonight', (
      tester,
    ) async {
      final s = store();
      tallWindow(tester);
      await tester.pumpWidget(app(s));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip, just pick something'));
      await tester.pumpAndSettle();
      final pick = tester
          .widget<Text>(find.byKey(const ValueKey('tonight-title')))
          .data;
      final before = (await saved(tester, s)).length;

      await tester.tap(navTab('Watchlist'));
      await tester.pumpAndSettle();
      for (final sort in WatchlistSort.values) {
        await chooseSort(tester, sort);
      }
      expect(find.byType(MovieListTile), findsNWidgets(before));
      expect(await saved(tester, s), hasLength(before));

      await tester.tap(navTab('Tonight'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('tonight-title'))).data,
        pick,
      );
      expect(find.text('Surprise me'), findsOneWidget);
    });

    testWidgets('a removed film stays removed under a non-default sort', (
      tester,
    ) async {
      final s = store();
      await openWatchlist(tester, s);
      await chooseSort(tester, WatchlistSort.titleAsc);
      await tester.drag(find.text('alpha'), const Offset(400, 0));
      await tester.pumpAndSettle();
      // The removal request starts when the slide-out ends; let it finish.
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('alpha'), findsNothing);
      expect(shown(tester, films.map((f) => f.title)), [
        'Bravo',
        'Charlie',
        'delta',
        'Echo',
        'Foxtrot',
      ]);
    });

    testWidgets('fits 320 px wide at 200% text, with the sheet reachable', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(640, 1280);
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await openWatchlist(tester, store(), tall: false);
      expect(tester.takeException(), isNull);
      for (final tip in ['Sort watchlist', 'Show as posters', 'Add movies']) {
        final r = tester.getRect(find.byTooltip(tip));
        expect(r.left, greaterThanOrEqualTo(0), reason: tip);
        expect(r.right, lessThanOrEqualTo(320), reason: tip);
      }
      await chooseSort(tester, WatchlistSort.runtimeDesc);
      expect(tester.takeException(), isNull);
      expect(shown(tester, films.map((f) => f.title)).first, 'Echo');
      await tester.tap(find.byTooltip('Show as posters'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
