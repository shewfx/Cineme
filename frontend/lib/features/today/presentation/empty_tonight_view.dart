import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/primary_action.dart';
import '../../../shared/models/today_state.dart';
import '../../series/application/series_support.dart';
import 'media_preference.dart';

/// Nothing to pick from for what Tonight is set to consider. It says why and
/// offers the matching way out; it never offers something else instead.
class EmptyTonightView extends ConsumerWidget {
  const EmptyTonightView({super.key, required this.envelope});

  final TodayEnvelope envelope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final shows = ref.watch(seriesEnabledProvider);
    final reason = shows ? envelope.emptyReason : 'none';
    final (title, body) = switch (reason) {
      'no_shows' => (
        'No shows in your watchlist yet',
        'Tonight is set to Shows only. Add a show or anime series, or '
            'change what Tonight considers.',
      ),
      'no_movies' => (
        'No movies in your watchlist',
        'Tonight is set to Movies only, and your watchlist has only shows. '
            'Add a film, or change what Tonight considers.',
      ),
      _ => (
        'Your watchlist is empty',
        shows
            ? 'Tonight picks one film or episode from your watchlist. Add a '
                  'few to start.'
            : 'Tonight picks one film from your watchlist. Add a few to start.',
      ),
    };
    final outlined = OutlinedButton.styleFrom(
      foregroundColor: AppColors.text,
      side: const BorderSide(color: AppColors.border),
      minimumSize: const Size.fromHeight(50),
    );
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: text.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  body,
                  style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                if (reason == 'no_shows') ...[
                  PrimaryAction(
                    label: 'Add shows',
                    onPressed: () => context.push('/search?media=shows'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    style: outlined,
                    onPressed: () => pickTonightMedia(context, ref, envelope),
                    child: const Text('Change preference'),
                  ),
                ] else if (reason == 'no_movies') ...[
                  PrimaryAction(
                    label: 'Add movies',
                    onPressed: () => context.push('/search'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    style: outlined,
                    onPressed: () => pickTonightMedia(context, ref, envelope),
                    child: const Text('Change preference'),
                  ),
                ] else ...[
                  PrimaryAction(
                    label: 'Add movies',
                    onPressed: () => context.push('/search'),
                  ),
                  if (shows) ...[
                    const SizedBox(height: 10),
                    OutlinedButton(
                      style: outlined,
                      onPressed: () => context.push('/search?media=shows'),
                      child: const Text('Add shows'),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
