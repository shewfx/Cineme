import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/state_views.dart';
import '../../../shared/models/today_state.dart';
import '../application/today_controller.dart';
import '../data/today_repository.dart';
import 'context_view.dart';
import 'recommendation_view.dart';
import 'today_intro.dart';
import 'today_states.dart';

class TodayPage extends ConsumerStatefulWidget {
  const TodayPage({super.key});

  @override
  ConsumerState<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends ConsumerState<TodayPage>
    with SingleTickerProviderStateMixin {
  /// Drives the opening and doubles as its minimum on-screen time.
  late final AnimationController _intro;
  late bool _held;

  @override
  void initState() {
    super.initState();
    final duration = ref.read(tonightIntroDurationProvider);
    _held = !ref.read(tonightIntroSeenProvider) && duration > Duration.zero;
    _intro = AnimationController(vsync: this, duration: duration);
    if (_held) {
      _intro.forward().whenComplete(() {
        if (!mounted) return;
        ref.read(tonightIntroSeenProvider.notifier).mark();
        setState(() => _held = false);
      });
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(todayRepositoryProvider) == null) {
      return const Scaffold(body: UnavailableView());
    }
    final body = _body(context);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      switchInCurve: Curves.easeOut,
      child: body,
    );
  }

  Widget _body(BuildContext context) {
    final today = ref.watch(todayEnvelopeProvider);
    // The opening shows while Today loads and, for a fresh setup screen, for
    // its short minimum; an existing pick is never delayed behind it.
    if (today.isLoading && !today.hasValue) {
      return TonightIntro(key: const ValueKey('intro'), progress: _intro);
    }
    final value = today.value;
    final setup =
        value != null &&
        (value.state == TodayStatus.notStarted ||
            value.state == TodayStatus.ready);
    if (_held && setup) {
      return TonightIntro(key: const ValueKey('intro'), progress: _intro);
    }
    return KeyedSubtree(
      key: const ValueKey('content'),
      child: today.when(
        loading: () => const SizedBox.shrink(),
        error: (_, _) => Scaffold(
          body: ErrorPanel(
            onRetry: () => ref.invalidate(todayEnvelopeProvider),
          ),
        ),
        data: (envelope) => switch (envelope.state) {
          TodayStatus.offered ||
          TodayStatus.accepted ||
          TodayStatus.completed => RecommendationView(envelope: envelope),
          TodayStatus.notStarted => const ContextView(),
          TodayStatus.ready => ContextView(
            key: const ValueKey('ready'),
            mode: ContextMode.ready,
            today: envelope,
          ),
          TodayStatus.paused => PausedView(envelope: envelope),
          TodayStatus.noMatch => NoMatchView(envelope: envelope),
          TodayStatus.emptyWatchlist => Scaffold(
            body: SafeArea(
              child: EmptyState(
                title: 'Your watchlist is empty',
                message: 'Tonight picks one film from your watchlist. Add a few to start.',
                actionLabel: 'Add movies',
                onAction: () => context.push('/search'),
              ),
            ),
          ),
        },
      ),
    );
  }
}
