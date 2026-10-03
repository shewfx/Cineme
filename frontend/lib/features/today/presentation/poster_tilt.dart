import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A restrained "card under glass" response for the Tonight poster: on hover
/// or while a finger is down on it, the card lifts a couple of pixels, grows
/// by under 1% and leans a fraction of a degree toward the pointer (the card's
/// face turns toward it, so the edge nearest the pointer recedes slightly), with a
/// faint highlight following it. Presentation only.
///
/// Layout and hit testing stay on the untransformed box: the [Listener] and
/// gesture recogniser sit outside the [Transform], so the touch area never
/// moves with the effect and no page geometry changes.
///
/// Touch: a gesture that starts on the poster is claimed immediately, so the
/// page does not scroll under the finger; the Listener keeps receiving that
/// pointer's events after it leaves the poster, until release or cancel. A
/// gesture that starts anywhere else scrolls the page as usual. With reduced
/// motion the poster is static and claims nothing.
class PosterTilt extends StatefulWidget {
  const PosterTilt({super.key, required this.child, this.borderRadius = 14});

  final Widget child;
  final double borderRadius;

  /// Limits of the effect, at the extreme corner of the poster.
  static const maxTiltRadians = 1.0 * math.pi / 180;
  static const liftPixels = 2.5;
  static const scaleGain = 0.008;
  static const glintOpacity = 0.07;

  @override
  State<PosterTilt> createState() => _PosterTiltState();
}

class _PosterTiltState extends State<PosterTilt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _engaged = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
    reverseDuration: const Duration(milliseconds: 280),
  );
  late final CurvedAnimation _eased = CurvedAnimation(
    parent: _engaged,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeInOut,
  );

  /// Pointer position in -1..1 on each axis; kept after release so the card
  /// eases back to rest along the way it came.
  final ValueNotifier<Offset> _position = ValueNotifier(Offset.zero);
  int? _touch;

  bool get _reduced => MediaQuery.disableAnimationsOf(context);

  @override
  void dispose() {
    _eased.dispose();
    _engaged.dispose();
    _position.dispose();
    super.dispose();
  }

  void _track(Offset local) {
    // This widget's own box: the poster itself, not the space around it.
    final size = context.size;
    if (size == null || size.isEmpty) return;
    _position.value = Offset(
      ((local.dx / size.width) * 2 - 1).clamp(-1.0, 1.0),
      ((local.dy / size.height) * 2 - 1).clamp(-1.0, 1.0),
    );
  }

  void _engage(Offset local) {
    if (_reduced) return;
    _track(local);
    _engaged.forward();
  }

  void _release() {
    _touch = null;
    _engaged.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = _reduced;
    if (reduced && _engaged.value != 0) _engaged.value = 0;
    Widget surface = AnimatedBuilder(
      animation: Listenable.merge([_eased, _position]),
      child: widget.child,
      builder: (context, child) {
        final t = _eased.value;
        if (t == 0) return child!;
        final p = _position.value;
        final matrix = Matrix4.identity()
          ..setEntry(3, 2, 0.0012)
          ..translateByDouble(0, -PosterTilt.liftPixels * t, 0, 1)
          ..rotateX(p.dy * PosterTilt.maxTiltRadians * t)
          ..rotateY(-p.dx * PosterTilt.maxTiltRadians * t)
          ..scaleByDouble(
            1 + PosterTilt.scaleGain * t,
            1 + PosterTilt.scaleGain * t,
            1,
            1,
          );
        return Transform(
          key: const ValueKey('poster-tilt-transform'),
          alignment: Alignment.center,
          transform: matrix,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              child!,
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(widget.borderRadius),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          // The light sits under the pointer.
                          center: Alignment(p.dx, p.dy),
                          radius: 0.85,
                          colors: [
                            Colors.white.withValues(
                              alpha: PosterTilt.glintOpacity * t,
                            ),
                            Colors.white.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );

    surface = MouseRegion(
      onEnter: (e) => _engage(e.localPosition),
      onHover: (e) {
        if (_reduced) return;
        _track(e.localPosition);
        if (!_engaged.isAnimating && _engaged.value == 0) _engaged.forward();
      },
      onExit: (_) => _release(),
      child: surface,
    );
    if (reduced) return surface;

    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        // Wins the gesture arena on touch-down, so a drag that begins on the
        // poster never becomes a page scroll. Mice are left alone.
        _TouchClaim: GestureRecognizerFactoryWithHandlers<_TouchClaim>(
          _TouchClaim.new,
          (_) {},
        ),
      },
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          if (e.kind == PointerDeviceKind.mouse) return;
          _touch ??= e.pointer;
          if (_touch == e.pointer) _engage(e.localPosition);
        },
        // Delivered to this box for the whole gesture, even outside it.
        onPointerMove: (e) {
          if (e.pointer == _touch) _track(e.localPosition);
        },
        onPointerUp: (e) {
          if (e.pointer == _touch) _release();
        },
        onPointerCancel: (e) {
          if (e.pointer == _touch) _release();
        },
        child: surface,
      ),
    );
  }
}

/// Claims every touch/stylus pointer that goes down on the poster.
class _TouchClaim extends EagerGestureRecognizer {
  _TouchClaim()
    : super(
        supportedDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
        },
      );
}
