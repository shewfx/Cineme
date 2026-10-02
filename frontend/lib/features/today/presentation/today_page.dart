import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/today_controller.dart';
import '../data/today_repository.dart';
import 'context_view.dart';
import 'recommendation_view.dart';

class TodayPage extends ConsumerWidget {
  const TodayPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(todayRepositoryProvider) == null) return const _Unavailable();
    final envelope = ref.watch(todayControllerProvider).pick?.value;
    return envelope == null
        ? const ContextView()
        : RecommendationView(envelope: envelope);
  }
}

/// Normal builds have no backend repository yet (P4) and never show fake data.
class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Cinemé', style: textTheme.displayMedium),
                const SizedBox(height: 12),
                Text('One movie. No scrolling.', style: textTheme.titleMedium),
                const SizedBox(height: 32),
                Text(
                  "Tonight's pick is not available in this build yet.",
                  style: textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
