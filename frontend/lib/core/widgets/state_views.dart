import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Plain cause for any failed load or action; never raw error text.
const connectionErrorMessage =
    "Couldn't reach Cinemé. Check your connection and try again.";

/// Reason plus at most one next action (FRONTEND_SPEC conventions).
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return _Centered(
      children: [
        Text(title, style: text.titleLarge, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          message,
          style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
          textAlign: TextAlign.center,
        ),
        if (actionLabel != null) ...[
          const SizedBox(height: 20),
          FilledButton(
            onPressed: onAction,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              minimumSize: const Size(160, 48),
              textStyle: const TextStyle(
                fontFamily: 'Jost',
                fontSize: 17,
                fontWeight: FontWeight.w500,
              ),
            ),
            child: Text(actionLabel!),
          ),
        ],
      ],
    );
  }
}

/// Plain cause and a permitted retry; callers keep any input or data.
class ErrorPanel extends StatelessWidget {
  const ErrorPanel({
    super.key,
    this.message = connectionErrorMessage,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return _Centered(
      children: [
        Text(
          message,
          style: text.bodyLarge?.copyWith(color: AppColors.textSoft),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: onRetry,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.text,
            side: const BorderSide(color: AppColors.border),
            minimumSize: const Size(120, 48),
          ),
          child: const Text('Retry'),
        ),
      ],
    );
  }
}

/// Inline retry row for a failed "load more"; existing items stay visible.
class LoadMoreRow extends StatelessWidget {
  const LoadMoreRow({super.key, required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (error == null) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        children: [
          Text(
            "Couldn't load more.",
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

/// Bounded initial-load skeleton: a few static rows, no endless shimmer.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.rows = 5});

  final int rows;

  @override
  Widget build(BuildContext context) {
    Widget bar(double width) => Container(
      height: 12,
      width: width,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(6),
      ),
    );
    return Semantics(
      label: 'Loading',
      child: ExcludeSemantics(
        child: ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          children: [
            for (var i = 0; i < rows; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 72,
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          bar(160),
                          const SizedBox(height: 10),
                          bar(100),
                        ],
                      ),
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

/// Shown by every screen in a normal build until real repositories exist.
class UnavailableView extends StatelessWidget {
  const UnavailableView({super.key, this.what = "Tonight's pick"});

  final String what;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return _Centered(
      children: [
        Text('Cinemé', style: textTheme.displayMedium),
        const SizedBox(height: 12),
        Text('One movie. No scrolling.', style: textTheme.titleMedium),
        const SizedBox(height: 32),
        Text(
          '$what is not available in this build yet.',
          style: textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    ),
  );
}
