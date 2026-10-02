import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/widgets/choice_pill.dart';
import '../../../core/widgets/movie_list_tile.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/tab_page.dart';
import '../../../shared/models/viewing.dart';
import '../application/history_controllers.dart';
import '../data/history_repository.dart';

/// Watched and Recommendations segments. Read-only in P1b.
class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  var _segment = 0;

  @override
  Widget build(BuildContext context) {
    if (ref.watch(historyRepositoryProvider) == null) {
      return const Scaffold(body: UnavailableView(what: 'History'));
    }
    return TabPage(
      title: 'History',
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
            // Pills wrap whole words at large text sizes.
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (i, label) in [
                    (0, 'Watched'),
                    (1, 'Recommendations'),
                  ])
                    ChoicePill(
                      label: label,
                      selected: _segment == i,
                      onTap: () => setState(() => _segment = i),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _segment == 0
                ? PagedListView<Viewing>(
                    value: ref.watch(viewingHistoryProvider),
                    empty: const EmptyState(
                      title: 'Nothing watched yet',
                      message: 'Films you record as watched appear here.',
                    ),
                    itemBuilder: (context, v) => MovieListTile(
                      key: ValueKey(v.id),
                      movie: v.movie,
                      lines: [
                        v.watchedAt != null
                            ? 'Watched ${shortDate(v.watchedAt!)}'
                            : 'Date unknown  ·  recorded ${shortDate(v.recordedAt)}',
                        v.rating?.label ?? 'No rating',
                      ],
                    ),
                    onRetry: () => ref.invalidate(viewingHistoryProvider),
                    onRefresh: () => ref.refresh(viewingHistoryProvider.future),
                    onLoadMore: ref
                        .read(viewingHistoryProvider.notifier)
                        .loadMore,
                  )
                : PagedListView<RecommendationRecord>(
                    value: ref.watch(recommendationHistoryProvider),
                    empty: const EmptyState(
                      title: 'No picks yet',
                      message: 'Each film Tonight picks for you appears here.',
                    ),
                    itemBuilder: (context, r) => MovieListTile(
                      key: ValueKey(r.id),
                      movie: r.movie,
                      lines: [
                        '${r.status.label}  ·  ${shortDate(r.createdAt)}',
                        'For “${r.desiredExperience.label}”',
                      ],
                    ),
                    onRetry: () =>
                        ref.invalidate(recommendationHistoryProvider),
                    onRefresh: () =>
                        ref.refresh(recommendationHistoryProvider.future),
                    onLoadMore: ref
                        .read(recommendationHistoryProvider.notifier)
                        .loadMore,
                  ),
          ),
        ],
      ),
    );
  }
}
