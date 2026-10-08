import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/choice_pill.dart';
import '../../../core/widgets/movie_list_tile.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/rating_stars.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/tab_page.dart';
import '../../../shared/models/series.dart';
import '../../../shared/models/viewing.dart';
import '../../series/application/series_controllers.dart';
import '../../series/application/series_support.dart';
import '../application/history_controllers.dart';
import '../data/history_repository.dart';
import '../../today/presentation/feedback_sheets.dart';

/// Watched and Recommendations segments. Read-only in P1b.
class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  var _segment = 0;

  Future<void> _editRating(BuildContext context, Viewing viewing) async {
    final result = await showRatingSheet(
      context,
      movie: viewing.movie,
      current: viewing.rating,
    );
    if (result == null || !result.$1 || !context.mounted) return;
    try {
      await ref
          .read(historyRepositoryProvider)!
          .rateViewing(viewing.id, result.$2, expectedVersion: viewing.version);
      ref.invalidate(viewingHistoryProvider);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Couldn't save your rating. Try again."),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(historyRepositoryProvider) == null) {
      return const Scaffold(body: UnavailableView(what: 'History'));
    }
    return TabPage(
      title: 'History',
      action: IconButton(
        tooltip: 'Log watched movie',
        onPressed: () => context.push('/search?mode=log'),
        icon: const Icon(Icons.add),
      ),
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
                    if (ref.watch(seriesEnabledProvider)) (2, 'Episodes'),
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
            child: _segment == 2
                ? PagedListView<EpisodeViewingRecord>(
                    value: ref.watch(episodeHistoryProvider),
                    empty: const EmptyState(
                      title: 'No episodes watched yet',
                      message: 'Episodes you mark watched appear here, separate from films.',
                    ),
                    itemBuilder: (context, v) => MovieListTile(
                      key: ValueKey(v.id),
                      movie: v.series,
                      lines: [
                        [v.code, ?v.episodeName].join('  ·  '),
                        v.watchedAt != null
                            ? 'Watched ${shortDate(v.watchedAt!)}'
                            : 'Date unknown  ·  recorded ${shortDate(v.recordedAt)}',
                      ],
                      footer: RatingStars(
                        rating: Rating.fromValue(v.rating),
                        size: 18,
                      ),
                    ),
                    onRetry: () => ref.invalidate(episodeHistoryProvider),
                    onRefresh: () => ref.refresh(episodeHistoryProvider.future),
                    onLoadMore: ref
                        .read(episodeHistoryProvider.notifier)
                        .loadMore,
                  )
                : _segment == 0
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
                      ],
                      footer: RatingStars(rating: v.rating, size: 18),
                      trailing: TextButton(
                        onPressed: () => _editRating(context, v),
                        child: Text(v.rating == null ? 'Rate' : 'Edit'),
                      ),
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
                    itemBuilder: (context, r) {
                      final lines = [
                        ?r.episodeLabel,
                        [
                          r.status.label,
                          ?r.reasonLabel,
                          shortDate(r.createdAt),
                        ].join('  ·  '),
                        'For “${r.desiredExperience.label}”',
                      ];
                      final movie = r.movie;
                      if (movie != null) {
                        return MovieListTile(
                          key: ValueKey(r.id),
                          movie: movie,
                          lines: lines,
                        );
                      }
                      // A no-match attempt has no film to show.
                      return Padding(
                        key: ValueKey(r.id),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 10,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Nothing fitted',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            for (final line in lines)
                              Text(
                                line,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(color: AppColors.textMuted),
                              ),
                          ],
                        ),
                      );
                    },
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
