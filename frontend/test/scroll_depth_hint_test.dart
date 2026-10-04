import 'package:cineme/core/widgets/scroll_depth_hint.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _scrollHarness({required bool long, VoidCallback? onTap}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      height: 240,
      child: ScrollDepthHint(
        child: Stack(
          fit: StackFit.expand,
          children: [
            SingleChildScrollView(
              child: SizedBox(
                height: long ? 800 : 160,
                child: const Align(
                  alignment: Alignment.topCenter,
                  child: Text('Film details'),
                ),
              ),
            ),
            if (onTap != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: FilledButton(
                  onPressed: onTap,
                  child: const Text('Action'),
                ),
              ),
          ],
        ),
      ),
    ),
  ),
);

double _opacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(find.byKey(const ValueKey('scroll-depth-hint')))
    .opacity;

void main() {
  testWidgets('stays hidden when content fits the viewport', (tester) async {
    await tester.pumpWidget(_scrollHarness(long: false));
    await tester.pumpAndSettle();

    expect(_opacity(tester), 0);
  });

  testWidgets(
    'appears for remaining content, fades at the end, and returns when scrolling up',
    (tester) async {
      await tester.pumpWidget(_scrollHarness(long: true));
      await tester.pumpAndSettle();
      expect(_opacity(tester), 1);

      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent - 80);
      await tester.pumpAndSettle();
      expect(_opacity(tester), greaterThan(0));
      expect(_opacity(tester), lessThan(1));

      scrollable.position.jumpTo(scrollable.position.maxScrollExtent - 20);
      await tester.pumpAndSettle();
      expect(_opacity(tester), 0);

      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(_opacity(tester), 0);

      scrollable.position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(_opacity(tester), 1);
    },
  );

  testWidgets('decorative glow does not block an action at the viewport edge', (
    tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(
      _scrollHarness(long: true, onTap: () => tapped = true),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Action'));
    expect(tapped, isTrue);
  });
}
