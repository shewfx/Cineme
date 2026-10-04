import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../shared/models/viewing.dart';
import '../application/today_controller.dart';

class FollowUpBanner extends ConsumerStatefulWidget {
  const FollowUpBanner({super.key, required this.prompt});
  final FollowUpPrompt prompt;

  @override
  ConsumerState<FollowUpBanner> createState() => _FollowUpBannerState();
}

class _FollowUpBannerState extends ConsumerState<FollowUpBanner> {
  bool busy = false;

  Future<void> act(String action) async {
    setState(() => busy = true);
    try {
      await ref
          .read(todayControllerProvider.notifier)
          .resolveFollowUp(widget.prompt, action);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't save that. Try again.")),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.surface,
    elevation: 8,
    borderRadius: BorderRadius.circular(16),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Did you watch ${widget.prompt.movie.title}?',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Wrap(
            spacing: 4,
            children: [
              TextButton(
                onPressed: busy ? null : () => act('yes'),
                child: const Text('Yes, I watched it'),
              ),
              TextButton(
                onPressed: busy ? null : () => act('no'),
                child: const Text("No, I didn't"),
              ),
              TextButton(
                onPressed: busy ? null : () => act('not_yet'),
                child: const Text('Not yet'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
