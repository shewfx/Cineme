import 'package:flutter/material.dart';

/// Mutable pointer exclusions shared by the tab shell and interactive children.
class TabSwipeTracker {
  final excludedPointers = <int>{};
}

class TabSwipeScope extends InheritedWidget {
  const TabSwipeScope({super.key, required this.tracker, required super.child});

  final TabSwipeTracker tracker;

  static TabSwipeTracker? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TabSwipeScope>()?.tracker;

  @override
  bool updateShouldNotify(TabSwipeScope oldWidget) =>
      tracker != oldWidget.tracker;
}

/// Marks a pointer as owned by a child interaction while leaving that
/// interaction's own gesture recognizer untouched.
class ExcludeTabSwipe extends StatelessWidget {
  const ExcludeTabSwipe({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tracker = TabSwipeScope.maybeOf(context);
    if (tracker == null) return child;
    return Listener(
      onPointerDown: (event) => tracker.excludedPointers.add(event.pointer),
      child: child,
    );
  }
}
