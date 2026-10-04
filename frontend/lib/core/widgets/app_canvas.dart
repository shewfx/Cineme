import 'package:flutter/material.dart';

/// True below [AppCanvas] while a wide window is held to the phone-width
/// canvas, so a screen can tell a tall desktop browser from a phone.
class AppCanvasScope extends InheritedWidget {
  const AppCanvasScope({super.key, required super.child});

  static bool constrained(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppCanvasScope>() != null;

  @override
  bool updateShouldNotify(AppCanvasScope oldWidget) => false;
}

/// Keeps the phone layout on wide browser windows: the app is a centred
/// canvas of at most [maxWidth], never a stretched or multi-column page.
/// Below that width it is transparent, so phones see the app unchanged.
///
/// The [MediaQuery] size is narrowed to the canvas so width-based layout
/// decisions inside the app match what is actually on screen.
class AppCanvas extends StatelessWidget {
  const AppCanvas({super.key, required this.child, this.maxWidth = 480});

  final Widget child;
  final double maxWidth;

  static const _outside = Color(0xFF111111);
  static const _edge = Color(0x1FFFFFFF);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    if (media.size.width <= maxWidth) return child;
    return ColoredBox(
      color: _outside,
      child: Center(
        child: SizedBox(
          width: maxWidth,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: const BoxDecoration(
              border: Border.symmetric(vertical: BorderSide(color: _edge)),
            ),
            child: MediaQuery(
              data: media.copyWith(size: Size(maxWidth, media.size.height)),
              child: AppCanvasScope(child: ClipRect(child: child)),
            ),
          ),
        ),
      ),
    );
  }
}
