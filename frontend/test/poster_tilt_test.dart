import 'dart:math' as math;

import 'package:cineme/features/today/presentation/poster_tilt.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'real_today_test.dart' show pickExciting, start;
import 'tonight_hero_test.dart' show window;

Finder get card => find.byKey(const ValueKey('tonight-poster-card'));
Finder get tilt => find.byKey(const ValueKey('tonight-poster-tilt'));
Finder get effect => find.byKey(const ValueKey('poster-tilt-transform'));
Finder get title => find.byKey(const ValueKey('tonight-title'));

ScrollableState page(WidgetTester tester) => tester.state<ScrollableState>(
  find.ancestor(of: tilt, matching: find.byType(Scrollable)).first,
);

/// Everything around the poster that must not move while it reacts.
Map<String, Rect> geometry(WidgetTester tester) => {
  'tilt box': tester.getRect(tilt),
  'title': tester.getRect(title),
  'hero': tester.getRect(find.byKey(const ValueKey('tonight-hero-dim'))),
  'nav': tester.getRect(find.byKey(const ValueKey('floating-nav'))),
};

Future<void> openPick(WidgetTester tester) async {
  await start(tester);
  await pickExciting(tester);
}

/// Total lean in degrees of the effect transform (largest of the two axes).
double leanDegrees(WidgetTester tester) {
  final m = tester.widget<Transform>(effect).transform;
  // With a tiny rotation, the off-diagonal terms are sin(angle).
  final x = math.asin(m.entry(2, 1).abs().clamp(0, 1));
  final y = math.asin(m.entry(2, 0).abs().clamp(0, 1));
  return math.max(x, y) * 180 / math.pi;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('poster tilt: desktop pointer', () {
    testWidgets('hover leans toward the pointer, within the tiny limits', (
      tester,
    ) async {
      window(tester, const Size(1440, 900));
      await openPick(tester);
      expect(effect, findsNothing, reason: 'no transform at rest');
      final before = geometry(tester);
      final rest = tester.getRect(card);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(5, 5));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(rest.bottomRight - const Offset(2, 2));
      await tester.pumpAndSettle();

      expect(effect, findsOneWidget);
      final m = tester.widget<Transform>(effect).transform;
      expect(leanDegrees(tester), inInclusiveRange(0.5, 1.25));
      // Lifts 2-3 px and grows by about one percent at most.
      expect(m.getTranslation().y, inInclusiveRange(-3.0, -2.0));
      expect(m.entry(0, 0), inInclusiveRange(1.0, 1.01));
      // Pointer to the right/bottom: the right edge recedes (-Y), bottom too (+X).
      expect(m.entry(2, 0), greaterThan(0));
      expect(m.entry(2, 1), greaterThan(0));
      // A faint highlight, never a flash.
      final glint = tester
          .widgetList<DecoratedBox>(
            find.descendant(of: effect, matching: find.byType(DecoratedBox)),
          )
          .map((d) => d.decoration)
          .whereType<BoxDecoration>()
          .map((d) => d.gradient)
          .whereType<RadialGradient>()
          .single;
      expect(glint.colors.first.a, lessThanOrEqualTo(0.08));
      expect(glint.center, isNot(Alignment.center));
      // Nothing around the poster moved.
      expect(geometry(tester), before);

      // The pointer moving to the opposite corner flips the lean.
      await mouse.moveTo(rest.topLeft + const Offset(2, 2));
      await tester.pumpAndSettle();
      final m2 = tester.widget<Transform>(effect).transform;
      expect(m2.entry(2, 0), lessThan(0));
      expect(m2.entry(2, 1), lessThan(0));
      expect(leanDegrees(tester), lessThanOrEqualTo(1.25));

      await mouse.moveTo(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(effect, findsNothing, reason: 'back to rest on leave');
      expect(geometry(tester), before);
      expect(tester.getRect(card), rest);
    });

    testWidgets('the blurred background stays fixed', (tester) async {
      window(tester, const Size(1440, 900));
      await openPick(tester);
      final bg = find.byType(ImageFiltered);
      final before = tester.getRect(bg);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(card));
      addTearDown(mouse.removePointer);
      await tester.pumpAndSettle();
      expect(effect, findsOneWidget);
      expect(
        find.descendant(of: effect, matching: find.byType(ImageFiltered)),
        findsNothing,
      );
      expect(tester.getRect(bg), before);
    });
  });

  group('poster tilt: touch', () {
    // 360x640 at 200% text: the page is taller than the screen, so it scrolls.
    Future<void> small(WidgetTester tester) async {
      window(tester, const Size(360, 640), scale: 2);
      await openPick(tester);
      expect(page(tester).position.maxScrollExtent, greaterThan(40));
    }

    testWidgets('a drag that starts on the poster does not scroll the page', (
      tester,
    ) async {
      await small(tester);
      final before = geometry(tester);
      final start = tester.getCenter(card);
      final g = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 200));
      var finger = start;
      for (var i = 1; i <= 8; i++) {
        finger += const Offset(4, -30);
        await g.moveTo(finger);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 300));

      expect(page(tester).position.pixels, 0, reason: 'poster owns the drag');
      expect(effect, findsOneWidget);
      expect(leanDegrees(tester), lessThanOrEqualTo(1.25));
      expect(geometry(tester), before, reason: 'no layout shift');

      // Finger long since outside the poster: still captured, still tracking.
      expect(tester.getRect(tilt).contains(finger), isFalse);
      await g.moveTo(finger += const Offset(0, -60));
      await tester.pump();
      expect(page(tester).position.pixels, 0);
      expect(effect, findsOneWidget);

      await g.up();
      await tester.pumpAndSettle();
      expect(effect, findsNothing, reason: 'released: back to rest');
      expect(page(tester).position.pixels, 0);

      // Scrolling is restored straight away.
      final c = tester.getRect(card);
      await tester.dragFrom(
        Offset(c.left / 2, c.center.dy),
        const Offset(0, -150),
      );
      await tester.pumpAndSettle();
      expect(page(tester).position.pixels, greaterThan(0));
    });

    testWidgets('a swipe that starts beside the poster scrolls normally', (
      tester,
    ) async {
      await small(tester);
      final c = tester.getRect(card);
      final beside = Offset(c.left / 2, c.center.dy);
      expect(c.left, greaterThan(20), reason: 'there is space beside it');
      final g = await tester.startGesture(beside);
      for (var i = 0; i < 6; i++) {
        await g.moveBy(const Offset(0, -30));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(page(tester).position.pixels, greaterThan(40));
      expect(effect, findsNothing, reason: 'poster never reacted');
    });

    testWidgets('a swipe that crosses over the poster does not engage it', (
      tester,
    ) async {
      await small(tester);
      final c = tester.getRect(card);
      final g = await tester.startGesture(Offset(c.left / 2, c.center.dy));
      await g.moveBy(const Offset(0, -20));
      await g.moveTo(Offset(c.center.dx, c.center.dy));
      await tester.pump();
      expect(effect, findsNothing);
      await g.up();
    });

    testWidgets('cancel resets the poster and restores scrolling', (
      tester,
    ) async {
      await small(tester);
      final g = await tester.startGesture(tester.getCenter(card));
      await g.moveBy(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(effect, findsOneWidget);

      await g.cancel();
      await tester.pumpAndSettle();
      expect(effect, findsNothing);

      final c = tester.getRect(card);
      await tester.dragFrom(
        Offset(c.left / 2, c.center.dy),
        const Offset(0, -150),
      );
      await tester.pumpAndSettle();
      expect(page(tester).position.pixels, greaterThan(0));
    });

    testWidgets('a simple tap leaves nothing tilted or lit', (tester) async {
      await small(tester);
      final rest = tester.getRect(card);
      await tester.tap(card);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pumpAndSettle();
      expect(effect, findsNothing);
      expect(tester.getRect(card), rest);
    });
  });

  group('poster tilt: layout and accessibility', () {
    for (final (name, size, scale, canvas) in [
      ('iPhone', const Size(390, 844), 1.0, false),
      ('small phone', const Size(320, 568), 1.0, false),
      ('200% text', const Size(360, 640), 2.0, false),
      ('desktop 480 px canvas', const Size(1440, 900), 1.0, true),
    ]) {
      testWidgets('$name: the poster keeps its bounds while it reacts', (
        tester,
      ) async {
        window(tester, size, scale: scale, top: canvas ? 0 : 47);
        await openPick(tester);
        final before = geometry(tester);
        final rest = tester.getRect(card);
        expect(rest.height / rest.width, closeTo(1.5, 0.001));
        if (canvas) {
          expect(rest.center.dx, closeTo(size.width / 2, 0.5));
        }

        final g = await tester.startGesture(rest.center);
        await g.moveTo(rest.topRight - const Offset(3, -3));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        expect(geometry(tester), before);
        // While engaged the card moves by a few pixels at most.
        final live = tester.getRect(card);
        expect((live.center - rest.center).distance, lessThan(4));
        expect((live.width - rest.width).abs(), lessThan(rest.width * 0.02));
        await g.up();
        await tester.pumpAndSettle();
        expect(tester.getRect(card), rest);
      });
    }

    testWidgets('reduced motion keeps the poster static and unclaimed', (
      tester,
    ) async {
      window(tester, const Size(360, 640), scale: 2);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await openPick(tester);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(card));
      addTearDown(mouse.removePointer);
      await mouse.moveBy(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(effect, findsNothing);

      // Touch on the poster is not captured: the page scrolls as usual.
      await tester.dragFrom(tester.getCenter(card), const Offset(0, -150));
      await tester.pumpAndSettle();
      expect(effect, findsNothing);
      expect(page(tester).position.pixels, greaterThan(0));
    });

    test('the limits stay inside the brief', () {
      expect(
        PosterTilt.maxTiltRadians * 180 / math.pi,
        lessThanOrEqualTo(1.25),
      );
      expect(PosterTilt.liftPixels, inInclusiveRange(2, 3));
      expect(PosterTilt.scaleGain, lessThanOrEqualTo(0.01));
      expect(PosterTilt.glintOpacity, lessThanOrEqualTo(0.08));
    });
  });
}
