import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/movie_list_tile.dart';
import '../../../core/widgets/movie_poster.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/selector_field.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/tab_swipe_exclusion.dart';
import '../../../core/widgets/tab_page.dart';
import '../../../shared/models/inventory.dart';
import '../../history/application/history_controllers.dart';
import '../../history/data/history_repository.dart';
import '../../today/application/today_controller.dart';
import '../application/watchlist_controller.dart';
import '../data/watchlist_repository.dart';

/// Inventory management: inspect, add and remove. Not a way to pick tonight.
class WatchlistPage extends ConsumerWidget {
  const WatchlistPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(watchlistRepositoryProvider) == null) {
      return const Scaffold(body: UnavailableView(what: 'Your watchlist'));
    }
    final controller = ref.read(watchlistControllerProvider.notifier);
    final posters =
        ref.watch(watchlistLayoutProvider) == WatchlistLayout.posters;
    return TabPage(
      title: 'Watchlist',
      subtitle: 'Films you might watch. Tonight picks from here.',
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Sort watchlist',
            icon: const Icon(Icons.swap_vert_rounded),
            onPressed: () async {
              final current = ref.read(watchlistSortProvider);
              final picked = await showOptionSheet<WatchlistSort>(
                context,
                title: 'Sort by',
                options: [for (final s in WatchlistSort.values) (s, s.label)],
                selected: current,
              );
              final sort = picked?.$1;
              if (sort != null) {
                await ref.read(watchlistSortProvider.notifier).set(sort);
              }
            },
          ),
          IconButton(
            tooltip: posters ? 'Show as list' : 'Show as posters',
            icon: Icon(
              posters ? Icons.view_list_rounded : Icons.grid_view_rounded,
            ),
            onPressed: () => ref
                .read(watchlistLayoutProvider.notifier)
                .set(posters ? WatchlistLayout.list : WatchlistLayout.posters),
          ),
          IconButton(
            tooltip: 'Add movies',
            icon: const Icon(Icons.add),
            onPressed: () => context.push('/search'),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, box) => PagedListView<WatchlistEntry>(
          value: ref.watch(watchlistControllerProvider),
          empty: EmptyState(
            title: 'Your watchlist is empty',
            message: 'Add films you might like to watch. Tonight picks one from here.',
            actionLabel: 'Add movies',
            onAction: () => context.push('/search'),
          ),
          gridDelegate: posters ? _posterGrid(context, box.maxWidth) : null,
          gridPadding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
          itemBuilder: (context, entry) => posters
              ? _PosterTile(key: ValueKey(entry.id), entry: entry)
              : _WatchlistRow(key: ValueKey(entry.id), entry: entry),
          onRetry: () => ref.invalidate(watchlistControllerProvider),
          onRefresh: () => ref.refresh(watchlistControllerProvider.future),
          onLoadMore: controller.loadMore,
        ),
      ),
    );
  }
}

const _gridGap = 12.0;
const _titleGap = 8.0;

/// Three columns on normal phones, two when very narrow. Each tile is a
/// 2:3 poster plus room for a two-line title at the current text scale.
SliverGridDelegate _posterGrid(BuildContext context, double width) {
  final inner = width - 48;
  final columns = inner >= 280 ? 3 : 2;
  final tileWidth = (inner - _gridGap * (columns - 1)) / columns;
  final style = _titleStyle(context);
  final line =
      MediaQuery.textScalerOf(context).scale(style.fontSize!) * style.height!;
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    crossAxisSpacing: _gridGap,
    mainAxisSpacing: 20,
    mainAxisExtent: tileWidth * 1.5 + _titleGap + line * 2 + 2,
  );
}

TextStyle _titleStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodyMedium!
        .copyWith(color: AppColors.text, height: 1.3);

/// The one removal path for both layouts: no dialog, Undo instead. Returns
/// whether the entry was removed; failures are explained and keep it.
Future<bool> _removeWithUndo(
  BuildContext context,
  WidgetRef ref,
  WatchlistEntry entry,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final controller = ref.read(watchlistControllerProvider.notifier);
  final title = entry.movie.title;
  try {
    if (!await controller.remove(entry)) return false;
  } catch (_) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            "Couldn't remove “$title”. It's still in your watchlist.",
          ),
        ),
      );
    return false;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('Removed “$title”.'),
        persist: false,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            try {
              await controller.restore(entry);
            } catch (_) {
              messenger.showSnackBar(
                SnackBar(content: Text("Couldn't put back “$title”.")),
              );
            }
          },
        ),
      ),
    );
  return true;
}

List<String> _details(WatchlistEntry entry) => [
  yearAndRuntime(entry.movie),
  if (!entry.movie.released) 'Not released yet',
  'Added ${shortDate(entry.addedAt)}',
];

/// List row: swipe right to remove. Below the threshold it snaps back.
class _WatchlistRow extends ConsumerWidget {
  const _WatchlistRow({super.key, required this.entry});

  final WatchlistEntry entry;

  Future<void> _markWatched(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Mark “${entry.movie.title}” watched?'),
        content: const Text(
          'This records a past viewing with an unknown date and archives it from your watchlist.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Mark watched'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref
          .read(historyRepositoryProvider)!
          .recordManual(entry.movie.tmdbId);
      ref
        ..invalidate(viewingHistoryProvider)
        ..invalidate(watchlistControllerProvider)
        ..invalidate(todayEnvelopeProvider);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't mark it watched. Try again.")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    return Semantics(
      // Swiping isn't reachable with a screen reader; this action is.
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Remove from watchlist'): () =>
            _removeWithUndo(context, ref, entry),
      },
      child: ExcludeTabSwipe(
        child: Dismissible(
          key: ValueKey('dismiss-${entry.id}'),
          direction: DismissDirection.startToEnd,
          dismissThresholds: const {DismissDirection.startToEnd: 0.4},
          confirmDismiss: (_) => _removeWithUndo(context, ref, entry),
          background: ColoredBox(
            color: AppColors.accent,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  const Icon(Icons.delete_outline, color: AppColors.background),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Remove',
                      overflow: TextOverflow.ellipsis,
                      style: text.titleMedium?.copyWith(
                        color: AppColors.background,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          child: ColoredBox(
            color: AppColors.background,
            child: InkWell(
              onTap: () =>
                  context.push('/movies/${entry.movie.tmdbId}', extra: entry),
              child: MovieListTile(
                movie: entry.movie,
                lines: _details(entry),
                trailing: ref.watch(historyRepositoryProvider) == null
                    ? null
                    : IconButton(
                        tooltip: 'Mark ${entry.movie.title} watched',
                        onPressed: () => _markWatched(context, ref),
                        icon: const Icon(Icons.check_circle_outline),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Poster tile: long-press for actions. No swipe in the grid.
class _PosterTile extends ConsumerWidget {
  const _PosterTile({super.key, required this.entry});

  final WatchlistEntry entry;

  Future<void> _actions(BuildContext context, WidgetRef ref) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                entry.movie.title,
                style: Theme.of(sheet).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: const Text('Mark watched'),
              onTap: () => Navigator.pop(sheet, 'watched'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Remove from watchlist'),
              onTap: () => Navigator.pop(sheet, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (action == 'remove' && context.mounted) {
      await _removeWithUndo(context, ref, entry);
    } else if (action == 'watched' && context.mounted) {
      await _WatchlistRow(entry: entry)._markWatched(context, ref);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final movie = entry.movie;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => context.push('/movies/${movie.tmdbId}', extra: entry),
      onLongPress: () => _actions(context, ref),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: MoviePoster(movie: movie),
            ),
          ),
          const SizedBox(height: _titleGap),
          Text(
            movie.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: _titleStyle(context),
          ),
        ],
      ),
    );
  }
}
