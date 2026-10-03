import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

export 'package:cineme/core/widgets/floating_nav_bar.dart' show FloatingNavBar;

/// A bottom-nav destination by its label. Inactive tabs show no text, so tests
/// reach them by key rather than by visible label.
Finder navTab(String label) => find.byKey(ValueKey('nav-$label'));

/// The four destinations, in order.
Finder get navItems => find.byWidgetPredicate((w) {
  final k = w.key;
  return k is ValueKey<String> && k.value.startsWith('nav-');
});
