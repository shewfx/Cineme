import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../shared/models/today_state.dart';
import '../data/today_repository.dart';
import 'recommendation_view.dart';

/// Component labels in engine order (RECOMMENDATION_ENGINE weights).
const _components = [
  ('G', 'Your genre preferences'),
  ('C', "Tonight's choice"),
  ('D', 'Variety'),
  ('A', 'Time in your watchlist'),
  ('R', 'Not suggested recently'),
  ('Q', 'TMDB rating'),
];

/// "Why this film?": the winner's stored reasons and, where the server has
/// it, its score breakdown. Never other films, never a confidence figure.
Future<void> showWhySheet(BuildContext context, Recommendation r) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (_) => _WhySheet(recommendation: r),
    );

class _WhySheet extends ConsumerStatefulWidget {
  const _WhySheet({required this.recommendation});

  final Recommendation recommendation;

  @override
  ConsumerState<_WhySheet> createState() => _WhySheetState();
}

class _WhySheetState extends ConsumerState<_WhySheet> {
  late final Future<WhyBreakdown?> _breakdown = ref
      .read(todayRepositoryProvider)!
      .why(widget.recommendation.id);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: AppColors.textMuted);
    final reasons = widget.recommendation.reasons;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                'Why “${widget.recommendation.movie.title}”',
                style: text.titleLarge,
              ),
            ),
            const SizedBox(height: 12),
            for (final r in reasons)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  reasonText(r),
                  style: isUncertain(r)
                      ? muted
                      : text.bodyLarge?.copyWith(color: AppColors.textSoft),
                ),
              ),
            FutureBuilder<WhyBreakdown?>(
              future: _breakdown,
              builder: (context, snapshot) {
                final b = snapshot.data;
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: LinearProgressIndicator(minHeight: 2),
                  );
                }
                if (b == null) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 12),
                    Text('How it scored', style: text.titleMedium),
                    const SizedBox(height: 8),
                    for (final (code, label) in _components)
                      if (b.weights.containsKey(code))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            children: [
                              Expanded(child: Text(label)),
                              Text(
                                '${b.contributions[code]!.toStringAsFixed(1)}'
                                ' of ${b.weights[code]!.toStringAsFixed(0)}',
                                style: muted,
                              ),
                            ],
                          ),
                        ),
                    const SizedBox(height: 8),
                    Text(
                      'Points from a fixed formula over your watchlist, not a '
                      'prediction. ${b.engineVersion} · ${b.configVersion}',
                      style: muted,
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
