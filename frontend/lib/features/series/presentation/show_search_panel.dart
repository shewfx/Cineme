import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/movie_list_tile.dart';
import '../../../core/widgets/state_views.dart';
import '../../../shared/models/series.dart';
import '../application/series_controllers.dart';
import 'show_discovery_grid.dart';

/// Search for shows and anime series to add. Same shape as the film search:
/// the field on top, results below, an explicit Add per row. Results are
/// labelled "Show" so media identity is never ambiguous.
class ShowSearchPanel extends ConsumerWidget {
  const ShowSearchPanel({super.key, this.leading, this.below});

  final Widget? leading;

  /// Rendered under the search field (the Movies | Shows control).
  final Widget? below;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(showSearchControllerProvider);
    final controller = ref.read(showSearchControllerProvider.notifier);
    final text = Theme.of(context).textTheme;

    final Widget body = switch (state.results) {
      // Nothing typed: this week's trending shows, with search still on top.
      null when state.query.isEmpty => const ShowDiscoveryGrid(),
      null => Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Type at least $showMinQueryLength letters to search.',
          style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
        ),
      ),
      AsyncLoading() => const SkeletonList(),
      AsyncError() => ErrorPanel(
        message:
            "Search isn't available right now. Your watchlist is unaffected.",
        onRetry: controller.retry,
      ),
      AsyncData(value: final results) when results.isEmpty => EmptyState(
        title: 'No shows match “${state.query}”',
        message: 'Check the spelling or try another title.',
      ),
      AsyncData(value: final results) => ListView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: results.length + (state.hasMore ? 1 : 0),
        itemBuilder: (context, i) {
          if (i < results.length) return _ShowRow(series: results[i]);
          if (state.loadMoreError == null && !state.loadingMore) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => controller.loadMore(),
            );
          }
          return LoadMoreRow(
            error: state.loadMoreError,
            onRetry: controller.loadMore,
          );
        },
      ),
    };

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(leading == null ? 24 : 8, 8, 24, 8),
          child: Row(
            children: [
              ?leading,
              Expanded(
                child: TextField(
                  autofocus: true,
                  onChanged: controller.onQueryChanged,
                  textInputAction: TextInputAction.search,
                  style: text.bodyLarge,
                  decoration: InputDecoration(
                    hintText: 'Search shows',
                    hintStyle: text.bodyLarge?.copyWith(
                      color: AppColors.textMuted,
                    ),
                    filled: true,
                    fillColor: AppColors.surface,
                    prefixIcon: const Icon(
                      Icons.search,
                      color: AppColors.textMuted,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadii.chip),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        ?below,
        Expanded(child: body),
      ],
    );
  }
}

class _ShowRow extends ConsumerWidget {
  const _ShowRow({required this.series});

  final Series series;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(showSearchControllerProvider);
    final busy = state.busy.contains(series.tmdbId);
    final added = state.added.contains(series.tmdbId);

    final Widget action;
    if (busy) {
      action = const SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      );
    } else if (added) {
      action = const _Status(Icons.bookmark, 'In watchlist');
    } else if (!series.canAdd) {
      action = const _Status(Icons.block, "Can't add");
    } else {
      action = OutlinedButton(
        onPressed: () => addShowWithFeedback(context, ref, series),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.accent,
          side: const BorderSide(color: AppColors.accent),
          minimumSize: const Size(0, 48),
        ),
        child: Text('Add', semanticsLabel: 'Add ${series.name} to watchlist'),
      );
    }
    final stacked = MediaQuery.textScalerOf(context).scale(10) > 13;
    return InkWell(
      onTap: () => context.push('/series/${series.tmdbId}'),
      child: MovieListTile(
        movie: series,
        large: true,
        lines: [
          ['Show', if (series.year != null) '${series.year}'].join('  ·  '),
          if (series.genres.isNotEmpty)
            series.genres.map((g) => g.name).join(', '),
        ],
        trailing: stacked ? null : action,
        footer: stacked ? action : null,
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: AppColors.textMuted),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: AppColors.textMuted),
        ),
      ],
    ),
  );
}

/// Adds a show and reports the outcome in one snack bar. A second tap while
/// the first is in flight does nothing (and says nothing).
Future<void> addShowWithFeedback(
  BuildContext context,
  WidgetRef ref,
  Series series,
) async {
  if (ref.read(showSearchControllerProvider).busy.contains(series.tmdbId)) {
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  final outcome = await ref
      .read(showSearchControllerProvider.notifier)
      .add(series);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(switch (outcome) {
          ShowAddOutcome.added => 'Added “${series.name}” to your watchlist.',
          ShowAddOutcome.alreadySaved =>
            '“${series.name}” is already in your watchlist.',
          ShowAddOutcome.blocked =>
            'You chose never to recommend “${series.name}”. Unblock it first.',
          ShowAddOutcome.ineligible => "“${series.name}” can't be added.",
          ShowAddOutcome.full => 'Your watchlist is full.',
          ShowAddOutcome.failed => connectionErrorMessage,
        }),
      ),
    );
}
