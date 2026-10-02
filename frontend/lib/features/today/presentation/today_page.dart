import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/state_views.dart';
import '../../../shared/models/today_state.dart';
import '../application/today_controller.dart';
import '../data/today_repository.dart';
import 'context_view.dart';
import 'recommendation_view.dart';
import 'today_states.dart';

class TodayPage extends ConsumerWidget {
  const TodayPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(todayRepositoryProvider) == null) {
      return const Scaffold(body: UnavailableView());
    }
    return ref
        .watch(todayEnvelopeProvider)
        .when(
          loading: () => const Scaffold(
            body: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
          ),
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
        );
  }
}
