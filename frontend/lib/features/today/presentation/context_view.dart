import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/primary_action.dart';
import '../../../shared/models/session_context.dart';
import '../application/today_controller.dart';
import 'today_widgets.dart';

/// Context first: desired experience (required), mood and time (optional).
class ContextView extends ConsumerWidget {
  const ContextView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(todayControllerProvider);
    final controller = ref.read(todayControllerProvider.notifier);
    final text = Theme.of(context).textTheme;
    final pick = state.pick;

    Widget choices(List<Widget> children) =>
        Wrap(spacing: 8, runSpacing: 8, children: children);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Wordmark(),
                    const SizedBox(height: 40),
                    Semantics(
                      header: true,
                      child: Text(
                        'What do you want from tonight?',
                        style: text.headlineMedium,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Choose the feeling. We pick one film from your watchlist.',
                      style: text.bodyMedium?.copyWith(
                        color: AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 24),
                    choices([
                      for (final intent in DesiredExperience.values)
                        ChoicePill(
                          label: intent.label,
                          selected: state.desiredExperience == intent,
                          onTap: () =>
                              controller.selectDesiredExperience(intent),
                        ),
                    ]),
                    const SizedBox(height: 32),
                    const SectionLabel(
                      'How are you feeling?',
                      note: 'Optional · never decides the pick',
                    ),
                    const SizedBox(height: 12),
                    choices([
                      for (final mood in CurrentMood.values)
                        ChoicePill(
                          label: mood.label,
                          selected: state.currentMood == mood,
                          onTap: () => controller.toggleMood(mood),
                        ),
                    ]),
                    const SizedBox(height: 28),
                    const SectionLabel('How much time?', note: 'Optional'),
                    const SizedBox(height: 12),
                    choices([
                      for (final (minutes, label) in runtimeOptions)
                        ChoicePill(
                          label: label,
                          selected: state.maxRuntimeMinutes == minutes,
                          onTap: () => controller.selectMaxRuntime(minutes),
                        ),
                    ]),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (pick is AsyncError) ...[
                    Text(
                      "Couldn't pick a movie. Your choices are kept; try again.",
                      textAlign: TextAlign.center,
                      style: text.bodyMedium?.copyWith(color: AppColors.accent),
                    ),
                    const SizedBox(height: 10),
                  ],
                  PrimaryAction(
                    label: 'Pick my movie',
                    disabledHint: 'Choose what you want from tonight first',
                    loading: pick?.isLoading ?? false,
                    onPressed: state.canPick ? controller.pickMyMovie : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
