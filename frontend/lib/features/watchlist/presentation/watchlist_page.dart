import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/movie_list_tile.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/tab_page.dart';
import '../../../shared/models/inventory.dart';
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
    return TabPage(
      title: 'Watchlist',
      subtitle: 'Films you might watch. Tonight picks from here.',
      action: IconButton(
        tooltip: 'Add movies',
        icon: const Icon(Icons.add),
        onPressed: () => context.push('/search'),
      ),
      child: PagedListView<WatchlistEntry>(
        value: ref.watch(watchlistControllerProvider),
        empty: EmptyState(
          title: 'Your watchlist is empty',
          message:
              'Add films you might like to watch. Tonight picks one from here.',
          actionLabel: 'Add movies',
          onAction: () => context.push('/search'),
        ),
        itemBuilder: (context, entry) =>
            _WatchlistRow(key: ValueKey(entry.id), entry: entry),
        onRetry: () => ref.invalidate(watchlistControllerProvider),
        onRefresh: () => ref.refresh(watchlistControllerProvider.future),
        onLoadMore: controller.loadMore,
      ),
    );
  }
}

class _WatchlistRow extends ConsumerStatefulWidget {
  const _WatchlistRow({super.key, required this.entry});

  final WatchlistEntry entry;

  @override
  ConsumerState<_WatchlistRow> createState() => _WatchlistRowState();
}

class _WatchlistRowState extends ConsumerState<_WatchlistRow> {
  bool _removing = false;

  Future<void> _confirmRemove() async {
    final title = widget.entry.movie.title;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Remove from watchlist?'),
        content: Text(
          '“$title” will leave your watchlist. You can add it again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _removing = true);
    try {
      await ref.read(watchlistControllerProvider.notifier).remove(widget.entry);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Removed “$title”.')));
    } catch (_) {
      if (mounted) setState(() => _removing = false);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              "Couldn't remove “$title”. It's still in your watchlist.",
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    return MovieListTile(
      movie: entry.movie,
      lines: [yearAndRuntime(entry.movie), 'Added ${shortDate(entry.addedAt)}'],
      trailing: _removing
          ? const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            )
          : IconButton(
              tooltip: 'Remove ${entry.movie.title}',
              icon: const Icon(Icons.close_rounded, color: AppColors.textMuted),
              onPressed: _confirmRemove,
            ),
    );
  }
}
