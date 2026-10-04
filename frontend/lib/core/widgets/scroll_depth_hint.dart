import 'package:flutter/material.dart';

/// A decorative glow that tracks whether useful content remains below the
/// current viewport. It observes the scrollable inside [child] and never
/// participates in hit testing.
class ScrollDepthHint extends StatefulWidget {
  const ScrollDepthHint({super.key, required this.child});

  final Widget child;

  @override
  State<ScrollDepthHint> createState() => _ScrollDepthHintState();
}

class _ScrollDepthHintState extends State<ScrollDepthHint> {
  double _opacity = 0;

  static const _minimumScrollableExtent = 24.0;
  static const _fadeDistance = 144.0;
  static const _hiddenAt = 32.0;

  bool _update(ScrollMetrics metrics) {
    if (metrics.axis != Axis.vertical) return false;
    final extent = metrics.maxScrollExtent;
    final remaining = (extent - metrics.pixels).clamp(0.0, extent);
    final opacity = extent <= _minimumScrollableExtent || remaining <= _hiddenAt
        ? 0.0
        : ((remaining - _hiddenAt) / (_fadeDistance - _hiddenAt)).clamp(
            0.0,
            1.0,
          );
    if ((opacity - _opacity).abs() > 0.001 && mounted) {
      setState(() => _opacity = opacity);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) => _update(notification.metrics),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) => _update(notification.metrics),
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 108,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  key: const ValueKey('scroll-depth-hint'),
                  opacity: _opacity,
                  duration: duration,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.bottomCenter,
                        radius: 1.25,
                        stops: [0, 0.48, 1],
                        colors: [
                          Color(0x20FF5046),
                          Color(0x0CFF5046),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
