import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/selector_field.dart';
import '../../../core/widgets/state_views.dart';
import '../../../shared/models/series.dart';
import '../../../shared/models/today_state.dart';
import '../../series/application/series_support.dart';

/// The current choice, whichever source knows it first.
TonightMedia currentTonightMedia(WidgetRef ref, TodayEnvelope? today) =>
    ref.watch(tonightMediaProvider) ?? today?.media ?? TonightMedia.movies;

/// "What to watch": Movies only, Movies & shows or Shows only. Saved for
/// every night on the server. Changing it clears an open pick (never picks a
/// replacement); an accepted plan is replaced only after a confirmation.
Future<void> pickTonightMedia(
  BuildContext context,
  WidgetRef ref,
  TodayEnvelope? today,
) async {
  final current = currentTonightMedia(ref, today);
  final picked = await showOptionSheet<TonightMedia>(
    context,
    title: 'What to watch',
    options: [for (final m in TonightMedia.values) (m, m.label)],
    selected: current,
  );
  final media = picked?.$1;
  if (media == null || media == current || !context.mounted) return;
  if (today?.state == TodayStatus.accepted) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text("Replace tonight's plan?"),
        content: Text(
          'You planned to watch “${today!.recommendation!.movie.title}”. '
          'Changing what to watch clears that plan. Nothing you have '
          'watched or saved changes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Keep plan'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
  }
  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref.read(tonightMediaProvider.notifier).set(media);
  } catch (_) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text(connectionErrorMessage)));
  }
}

/// The settings row used on the Tonight setup screens.
class MediaPreferenceField extends ConsumerWidget {
  const MediaPreferenceField({super.key, this.today});

  final TodayEnvelope? today;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SelectorField(
    label: 'What to watch',
    note: 'Saved for every night',
    value: currentTonightMedia(ref, today).label,
    onTap: () => pickTonightMedia(context, ref, today),
  );
}
