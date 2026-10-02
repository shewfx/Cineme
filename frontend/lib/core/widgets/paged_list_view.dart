import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/paged_list.dart';
import 'state_views.dart';

/// Initial skeleton, error with Retry, empty state, pull-to-refresh that
/// keeps data, and automatic "load more" with an inline retry row.
class PagedListView<T> extends StatelessWidget {
  const PagedListView({
    super.key,
    required this.value,
    required this.empty,
    required this.itemBuilder,
    required this.onRetry,
    required this.onRefresh,
    required this.onLoadMore,
  });

  final AsyncValue<PagedState<T>> value;
  final Widget empty;
  final Widget Function(BuildContext, T) itemBuilder;
  final VoidCallback onRetry;
  final Future<void> Function() onRefresh;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    return value.when(
      // A failed refresh keeps the rows already loaded (FRONTEND_SPEC).
      skipError: true,
      loading: () => const SkeletonList(),
      error: (_, _) => ErrorPanel(onRetry: onRetry),
      data: (s) {
        if (s.items.isEmpty) return empty;
        final extra = s.hasMore ? 1 : 0;
        return RefreshIndicator(
          onRefresh: () async {
            try {
              await onRefresh();
            } catch (_) {
              // Refresh failures keep the loaded rows and say so.
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    const SnackBar(
                      content: Text(
                        "Couldn't refresh. Showing what was already loaded.",
                      ),
                    ),
                  );
              }
            }
          },
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: s.items.length + extra,
            itemBuilder: (context, i) {
              if (i < s.items.length) return itemBuilder(context, s.items[i]);
              if (s.loadMoreError == null && !s.loadingMore) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => onLoadMore(),
                );
              }
              return LoadMoreRow(error: s.loadMoreError, onRetry: onLoadMore);
            },
          ),
        );
      },
    );
  }
}
