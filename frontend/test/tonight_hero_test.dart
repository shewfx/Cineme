import 'dart:ui' as ui;

import 'package:cineme/core/widgets/movie_poster.dart';
import 'package:cineme/features/today/presentation/recommendation_view.dart'
    show desktopHeroMaxHeight;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The real-API rig has no viewing history, like the hosted build, so Tonight
// shows its compact action bar.
import 'real_today_test.dart' show TodayRig, pickExciting, start;

void window(
  WidgetTester tester,
  Size logical, {
  double scale = 1,
  double top = 0,
  double bottom = 0,
  double dpr = 1,
}) {
  tester.view
    ..devicePixelRatio = dpr
    ..physicalSize = logical * dpr
    ..padding = FakeViewPadding(top: top * dpr, bottom: bottom * dpr)
    ..viewPadding = FakeViewPadding(top: top * dpr, bottom: bottom * dpr);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<void> openPick(WidgetTester tester) async {
  await start(tester);
  await pickExciting(tester);
}

Rect rect(WidgetTester tester, Finder f) => tester.getRect(f);

Finder get hero => find.byKey(const ValueKey('tonight-hero-dim'));
Finder get card => find.byKey(const ValueKey('tonight-poster-card'));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Tonight hero', () {
    testWidgets('takes about 60% of an iPhone-sized screen', (tester) async {
      window(tester, const Size(390, 844), top: 47, bottom: 34);
      await openPick(tester);

      final h = rect(tester, hero);
      expect(h.top, 0, reason: 'runs under the status bar');
      expect(h.width, 390);
      expect(h.height / 844, inInclusiveRange(0.55, 0.65));
    });

    testWidgets('the sharp poster card is whole, 2:3 and clear of the notch', (
      tester,
    ) async {
      window(tester, const Size(390, 844), top: 47, bottom: 34);
      await openPick(tester);

      final h = rect(tester, hero);
      final c = rect(tester, card);
      expect(c.height / c.width, closeTo(1.5, 0.001), reason: 'uncropped 2:3');
      expect(c.top, greaterThanOrEqualTo(47 + 16), reason: 'safe area kept');
      expect(h.contains(c.topLeft) && h.contains(c.bottomRight), isTrue);
      expect(c.center.dx, closeTo(195, 0.5), reason: 'centred');
      // A real card, not a thumbnail.
      expect(c.width, greaterThan(180));
      // Exactly one sharp poster for the one film.
      expect(find.byType(MoviePoster), findsOneWidget);
      expect(
        find.ancestor(of: card, matching: find.byType(ImageFiltered)),
        findsNothing,
        reason: 'the card itself is never blurred',
      );
    });

    testWidgets('the background is the blurred, dimmed artwork', (
      tester,
    ) async {
      window(tester, const Size(390, 844), top: 47, bottom: 34);
      await openPick(tester);

      final blurs = tester.widgetList<ImageFiltered>(
        find.byType(ImageFiltered),
      );
      expect(blurs, hasLength(1));
      // ImageFilter.blur: a real blur, not a no-op.
      expect(blurs.single.imageFilter, isA<ui.ImageFilter>());
      // Dim and fade layer ends in the page's charcoal.
      final dim = tester.widget<DecoratedBox>(hero);
      final gradient =
          (dim.decoration as BoxDecoration).gradient! as LinearGradient;
      expect(gradient.colors.last, const Color(0xFF1C1C1C));
    });

    testWidgets('details follow the hero: title, meta, actions, in order', (
      tester,
    ) async {
      window(tester, const Size(390, 844), top: 47, bottom: 34);
      await openPick(tester);

      final h = rect(tester, hero);
      final title = rect(tester, find.byKey(const ValueKey('tonight-title')));
      final meta = rect(tester, find.byKey(const ValueKey('tonight-meta')));
      expect(title.top, greaterThanOrEqualTo(h.bottom - 1));
      expect(meta.top, greaterThan(title.bottom));
      // Centred under the card.
      expect(title.center.dx, closeTo(195, 1));
      expect(meta.center.dx, closeTo(195, 1));

      // The pinned actions are visible without scrolling, side by side.
      final watch = find.widgetWithText(FilledButton, 'Watch Tonight');
      final notFeeling = find.widgetWithText(OutlinedButton, 'Not feeling it');
      expect(watch.hitTestable(), findsOneWidget);
      expect(notFeeling.hitTestable(), findsOneWidget);
      expect(
        rect(tester, watch).center.dy,
        closeTo(rect(tester, notFeeling).center.dy, 1),
      );
      expect(rect(tester, watch).bottom, lessThanOrEqualTo(844 - 34 - 80));
      // The two links stay on the page.
      expect(find.text('Edit tonight'), findsOneWidget);
      expect(find.text('Why this film?'), findsOneWidget);
    });

    testWidgets('a short screen shrinks the hero, never hides the actions', (
      tester,
    ) async {
      window(tester, const Size(360, 640));
      await openPick(tester);

      final h = rect(tester, hero);
      expect(h.height, greaterThanOrEqualTo(220));
      expect(h.height / 640, lessThan(0.62));
      expect(
        find.widgetWithText(FilledButton, 'Watch Tonight').hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('320 px wide at 200% text: no overflow, stacked actions', (
      tester,
    ) async {
      window(tester, const Size(320, 640), scale: 2, dpr: 2);
      await openPick(tester);

      expect(tester.takeException(), isNull);
      final h = rect(tester, hero);
      expect(h.height, greaterThanOrEqualTo(220));
      expect(h.height / 640, lessThanOrEqualTo(0.45), reason: 'room for text');
      final watch = find.widgetWithText(FilledButton, 'Watch Tonight');
      final notFeeling = find.widgetWithText(OutlinedButton, 'Not feeling it');
      expect(watch.hitTestable(), findsOneWidget);
      expect(
        rect(tester, notFeeling).top,
        greaterThan(rect(tester, watch).bottom),
        reason: 'stacked, primary first',
      );
      // The title is reachable by scrolling the page.
      await tester.ensureVisible(find.byKey(const ValueKey('tonight-title')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('on a wide desktop browser it stays in the 480 px canvas', (
      tester,
    ) async {
      window(tester, const Size(1440, 900));
      await tester.pumpWidget(TodayRig().app(canvas: true));
      await tester.pumpAndSettle();
      await pickExciting(tester);

      final h = rect(tester, hero);
      final c = rect(tester, card);
      expect(h.width, 480);
      expect(h.center.dx, closeTo(720, 0.5));
      expect(c.center.dx, closeTo(720, 0.5));
      expect(c.width, lessThanOrEqualTo(480 * 0.6 + 0.5));
      expect(h.height / 900, inInclusiveRange(0.5, 0.65));
    });

    testWidgets('the hero ends on a whole pixel, so no seam line shows', (
      tester,
    ) async {
      // 60% of 932 is 559.2: a fractional edge would paint a faint line.
      window(tester, const Size(430, 932), top: 59, bottom: 34, dpr: 3);
      await openPick(tester);

      final h = rect(tester, hero);
      expect(h.height, h.height.floorToDouble());
      expect(h.bottom, h.bottom.floorToDouble());
      expect(h.height / 932, inInclusiveRange(0.55, 0.61));
    });

    testWidgets('a very tall desktop window caps the hero', (tester) async {
      window(tester, const Size(1440, 1600));
      await tester.pumpWidget(TodayRig().app(canvas: true));
      await tester.pumpAndSettle();
      await pickExciting(tester);

      final h = rect(tester, hero);
      expect(h.width, 480);
      expect(
        h.height,
        desktopHeroMaxHeight,
        reason: '60% of 1600 would be 960',
      );
      final c = rect(tester, card);
      expect(h.contains(c.topLeft) && h.contains(c.bottomRight), isTrue);
      expect(c.height / c.width, closeTo(1.5, 0.001));
    });

    testWidgets('a tall phone keeps the 60% hero; only desktop is capped', (
      tester,
    ) async {
      window(tester, const Size(430, 1000), top: 47, bottom: 34);
      await openPick(tester);

      final h = rect(tester, hero);
      expect(h.height, greaterThan(desktopHeroMaxHeight));
      expect(h.height / 1000, inInclusiveRange(0.55, 0.61));
    });

    testWidgets('accepted plans keep the same hero and a single action', (
      tester,
    ) async {
      window(tester, const Size(390, 844), top: 47, bottom: 34);
      await openPick(tester);
      await tester.tap(find.text('Watch Tonight'));
      await tester.pumpAndSettle();

      expect(find.text("Tonight's plan"), findsOneWidget);
      expect(find.byType(MoviePoster), findsOneWidget);
      expect(rect(tester, hero).height / 844, inInclusiveRange(0.55, 0.65));
      expect(find.text('Change my mind').hitTestable(), findsOneWidget);
    });
  });
}
