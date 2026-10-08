import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/movie_poster.dart';
import '../../../shared/models/series.dart';

/// The pieces of the add screen's discovery grid, shared by films and shows:
/// one bounded page of poster cards (poster, title, year, Add or Added),
/// two columns on a narrow phone and more as the width allows, with the same
/// loading, retry and empty states. Nothing here knows the media type.
const discoveryInset = 24.0;
const discoveryGap = 16.0;
const _minCell = 160.0;

/// Scroll frame: optional selector, the header and subtitle, then [content].
class DiscoveryFrame extends StatelessWidget {
  const DiscoveryFrame({
    super.key,
    this.selector,
    this.title,
    required this.subtitle,
    required this.content,
  });

  final Widget? selector;

  /// Shown as the heading when there is no selector carrying the title.
  final String? title;
  final String subtitle;
  final Widget content;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (selector != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                discoveryInset,
                4,
                discoveryInset,
                4,
              ),
              child: selector,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              discoveryInset,
              8,
              discoveryInset,
              12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null) ...[
                  Semantics(
                    header: true,
                    child: Text(title!, style: text.titleMedium),
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  subtitle,
                  style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          content,
        ],
      ),
    );
  }
}

/// Cards laid out responsively: at least two columns.
class DiscoveryWrap extends StatelessWidget {
  const DiscoveryWrap({super.key, required this.cells});

  /// Each cell is sized by this widget; give each its own key.
  final List<Widget> cells;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final inner = box.maxWidth - 2 * discoveryInset;
      final columns = (inner / (_minCell + discoveryGap)).floor().clamp(2, 6);
      final width = (inner - discoveryGap * (columns - 1)) / columns;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: discoveryInset),
        child: Wrap(
          spacing: discoveryGap,
          runSpacing: 20,
          children: [
            for (final cell in cells)
              SizedBox(
                key: ValueKey(('slot', cell.key)),
                width: width,
                child: cell,
              ),
          ],
        ),
      );
    },
  );
}

class DiscoveryNote extends StatelessWidget {
  const DiscoveryNote(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: discoveryInset),
    child: Text(
      message,
      style: Theme.of(context).textTheme.bodyMedium
          ?.copyWith(color: AppColors.textMuted),
    ),
  );
}

class DiscoverySkeleton extends StatelessWidget {
  const DiscoverySkeleton({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: discoveryInset),
        child: Row(
          children: [
            for (var i = 0; i < 2; i++) ...[
              if (i > 0) const SizedBox(width: discoveryGap),
              Expanded(
                child: AspectRatio(
                  aspectRatio: 2 / 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// A failed list: says so, keeps search usable, offers Retry.
class DiscoveryRetry extends StatelessWidget {
  const DiscoveryRetry({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: discoveryInset),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(
            "Couldn't load this list. You can still search above.",
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: AppColors.textSoft),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: onRetry,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.text,
            side: const BorderSide(color: AppColors.border),
            minimumSize: const Size(0, 48),
          ),
          child: const Text('Retry'),
        ),
      ],
    ),
  );
}

/// Poster, title, year, then the [action] (Add, Added, busy...).
class DiscoveryCell extends StatelessWidget {
  const DiscoveryCell({super.key, required this.info, required this.action});

  final TitleInfo info;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 2 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: MoviePoster(movie: info),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          info.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: text.titleSmall,
        ),
        if (info.year != null)
          Text(
            '${info.year}',
            style: text.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        const SizedBox(height: 6),
        action,
      ],
    );
  }
}

class DiscoveryBusy extends StatelessWidget {
  const DiscoveryBusy({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 48,
    child: Center(
      child: SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    ),
  );
}

class DiscoveryAddButton extends StatelessWidget {
  const DiscoveryAddButton({
    super.key,
    required this.title,
    required this.onPressed,
  });

  final String title;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.accent,
        side: const BorderSide(color: AppColors.accent),
        minimumSize: const Size(0, 48),
      ),
      child: Text('Add', semanticsLabel: 'Add $title to watchlist'),
    ),
  );
}

class DiscoveryStatus extends StatelessWidget {
  const DiscoveryStatus(
    this.icon,
    this.label,
    this.semanticsLabel, {
    super.key,
  });

  final IconData icon;
  final String label;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticsLabel,
    child: ExcludeSemantics(
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            Icon(icon, size: 18, color: AppColors.textMuted),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: AppColors.textMuted),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
