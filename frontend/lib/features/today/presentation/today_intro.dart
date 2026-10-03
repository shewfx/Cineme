import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import 'today_widgets.dart';

/// How long the branded opening holds before the Tonight setup appears.
/// Short on purpose; tests override it.
final tonightIntroDurationProvider = Provider<Duration>(
  (ref) => const Duration(milliseconds: 900),
);

/// The intro plays once per app launch, not on every tab switch.
class TonightIntroSeen extends Notifier<bool> {
  @override
  bool build() => false;

  void mark() => state = true;
}

final tonightIntroSeenProvider = NotifierProvider<TonightIntroSeen, bool>(
  TonightIntroSeen.new,
);

/// "Tonight’s the night." on charcoal: the wordmark, one line of Jost and a
/// thin coral rule that draws in. Also the loading state while Today loads.
class TonightIntro extends StatelessWidget {
  const TonightIntro({super.key, this.progress});

  /// 0..1 over the intro; null shows the settled state (plain loading).
  final Animation<double>? progress;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final t = progress ?? const AlwaysStoppedAnimation(1.0);
    return Scaffold(
      body: SafeArea(
        // Decorative and non-interactive: text is capped at 1.3x and the block
        // scrolls rather than overflowing on very small screens.
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.3,
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: AnimatedBuilder(
                animation: t,
                builder: (context, _) {
                  final fade = Curves.easeOut.transform(
                    (t.value / 0.2).clamp(0.0, 1.0),
                  );
                  final rule = Curves.easeInOut.transform(
                    ((t.value - 0.1) / 0.5).clamp(0.0, 1.0),
                  );
                  return Semantics(
                    liveRegion: true,
                    label: 'Tonight’s the night. Loading.',
                    child: ExcludeSemantics(
                      child: Opacity(
                        opacity: fade,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Wordmark(),
                            const SizedBox(height: 28),
                            Text(
                              'Tonight’s the night.',
                              textAlign: TextAlign.center,
                              style: text.headlineMedium,
                            ),
                            const SizedBox(height: 20),
                            Container(
                              width: 56 * rule,
                              height: 2,
                              color: AppColors.accent,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
