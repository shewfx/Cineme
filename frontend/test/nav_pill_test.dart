import 'package:cineme/app.dart';
import 'package:cineme/preview/preview_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'nav_finders.dart';

const order = ['Tonight', 'Watchlist', 'History', 'Profile'];

Finder get floatingNav => find.byKey(const ValueKey('floating-nav'));

Future<void> open(WidgetTester tester, Size size, {double scale = 1}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size
    ..padding = const FakeViewPadding(bottom: 20)
    ..viewPadding = const FakeViewPadding(bottom: 20);
  addTearDown(tester.view.reset);
  if (scale != 1) {
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  await tester.pumpWidget(
    ProviderScope(
      retry: noAutomaticRetry,
      overrides: previewOverrides(PreviewStore(latency: Duration.zero)),
      child: const CinemeApp(),
    ),
  );
  await tester.pumpAndSettle();
}

Finder labelIn(String tab) =>
    find.descendant(of: navTab(tab), matching: find.text(tab));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('active tab shows icon + label, inactive tabs icon only', (
    tester,
  ) async {
    await open(tester, const Size(390, 844));
    for (final active in order) {
      await tester.tap(navTab(active));
      await tester.pumpAndSettle();
      for (final tab in order) {
        expect(
          labelIn(tab),
          tab == active ? findsOneWidget : findsNothing,
          reason: '$tab while $active is active',
        );
        expect(
          find.descendant(of: navTab(tab), matching: find.byType(Icon)),
          findsOneWidget,
        );
      }
    }
  });

  testWidgets('every destination keeps its semantic label and tooltip', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await open(tester, const Size(390, 844));
    for (final tab in order) {
      expect(
        find.bySemanticsLabel(tab),
        findsWidgets,
        reason: '$tab is announced',
      );
      final node = tester.getSemantics(navTab(tab));
      expect(node.label, tab);
      // Tapping a tab by its semantics works while its text is hidden.
      expect(find.byTooltip(tab), findsOneWidget, reason: tab);
    }
    handle.dispose();
  });

  testWidgets('tapping each destination opens that tab', (tester) async {
    await open(tester, const Size(390, 844));
    for (final tab in [...order.reversed, ...order]) {
      await tester.tapAt(tester.getCenter(navTab(tab)));
      await tester.pumpAndSettle();
      final nav = tester.widget<FloatingNavBar>(find.byType(FloatingNavBar));
      expect(nav.selectedIndex, order.indexOf(tab), reason: tab);
    }
  });

  for (final (name, size, scale) in [
    ('iPhone', const Size(390, 844), 1.0),
    ('small phone', const Size(320, 568), 1.0),
    ('small phone at 200% text', const Size(320, 568), 2.0),
    ('desktop canvas', const Size(1440, 900), 1.0),
  ]) {
    testWidgets(
      '$name: one row, 48 px targets, no overflow for any active tab',
      (tester) async {
        await open(tester, size, scale: scale);
        for (final tab in order) {
          await tester.tap(navTab(tab));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$name $tab');
          final bar = tester.getRect(floatingNav);
          final rects = [
            for (var i = 0; i < 4; i++) tester.getRect(navItems.at(i)),
          ];
          expect({for (final r in rects) r.center.dy.round()}, hasLength(1));
          for (final r in rects) {
            expect(r.height, greaterThanOrEqualTo(48));
            expect(r.width, greaterThanOrEqualTo(48));
            expect(r.left, greaterThanOrEqualTo(bar.left));
            expect(r.right, lessThanOrEqualTo(bar.right));
          }
          for (var i = 1; i < 4; i++) {
            expect(rects[i].left, greaterThanOrEqualTo(rects[i - 1].right));
          }
          expect(tester.getRect(navTab(tab)).width, greaterThan(48));
        }
      },
    );
  }

  testWidgets('the pill is plain layout: no transform above it', (
    tester,
  ) async {
    await open(tester, const Size(390, 844));
    expect(
      find.ancestor(of: navItems.first, matching: find.byType(Transform)),
      findsNothing,
    );
  });

  group('compact constant-width capsule', () {
    for (final (name, size, scale, expected) in [
      ('iPhone', const Size(390, 844), 1.0, 316.0),
      ('Android 360', const Size(360, 800), 1.0, 304.0),
      ('small phone', const Size(320, 568), 1.0, 264.0),
      ('very narrow', const Size(280, 560), 1.0, 224.0),
      ('200% text', const Size(360, 640), 2.0, 304.0),
      ('desktop 480 canvas', const Size(1440, 900), 1.0, 316.0),
    ]) {
      testWidgets('$name: shell is ${expected}px for every active tab', (
        tester,
      ) async {
        await open(tester, size, scale: scale);
        final shells = <Rect>[];
        for (final tab in order) {
          await tester.tap(navTab(tab));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$name $tab');
          shells.add(tester.getRect(floatingNav));
          // Four destinations, each still tappable at its own centre.
          for (var i = 0; i < 4; i++) {
            final r = tester.getRect(navItems.at(i));
            expect(r.width, greaterThanOrEqualTo(48));
            expect(r.height, greaterThanOrEqualTo(48));
          }
        }
        for (final r in shells) {
          expect(r, shells.first, reason: 'shell never moves or resizes');
        }
        final shell = shells.first;
        expect(shell.width, expected);
        final viewport = name == 'desktop 480 canvas' ? 480.0 : size.width;
        final left = name == 'desktop 480 canvas'
            ? (size.width - 480) / 2 + (480 - expected) / 2
            : (size.width - expected) / 2;
        expect(shell.left, closeTo(left, 0.5));
        expect(
          shell.left - (size.width - viewport) / 2,
          greaterThanOrEqualTo(28),
          reason: 'safe side margin',
        );
        if (name == 'desktop 480 canvas') {
          expect(shell.width, lessThan(480 - 56), reason: 'not canvas-wide');
        }
      });
    }

    testWidgets('Watchlist fits its fixed slot without overflow', (
      tester,
    ) async {
      await open(tester, const Size(320, 568), scale: 2);
      await tester.tap(navTab('Watchlist'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final pill = tester.getRect(navTab('Watchlist'));
      final label = tester.getRect(labelIn('Watchlist'));
      expect(label.left, greaterThanOrEqualTo(pill.left));
      expect(label.right, lessThanOrEqualTo(pill.right));
    });

    testWidgets('every tab still routes after the resize', (tester) async {
      await open(tester, const Size(390, 844));
      for (final tab in [...order.reversed, ...order]) {
        await tester.tapAt(tester.getCenter(navTab(tab)));
        await tester.pumpAndSettle();
        final nav = tester.widget<FloatingNavBar>(find.byType(FloatingNavBar));
        expect(nav.selectedIndex, order.indexOf(tab), reason: tab);
      }
    });
  });
}
