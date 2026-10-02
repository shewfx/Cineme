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
    this.gridDelegate,
    this.gridPadding = EdgeInsets.zero,
  });

  final AsyncValue<PagedState<T>> value;
  final Widget empty;
  final Widget Function(BuildContext, T) itemBuilder;
  final VoidCallback onRetry;
  final Future<void> Function() onRefresh;
  final VoidCallback onLoadMore;

  /// Set to lay the items out as a grid instead of a list.
  final SliverGridDelegate? gridDelegate;
  final EdgeInsets gridPadding;

  /// Building the last item (lazily, near the end) asks for the next page.
  /// Slivers always build their first child, so the trigger can't live in
  /// a separate trailing sliver.
  Widget item(BuildContext context, PagedState<T> s, int i) {
    if (i == s.items.length - 1 &&
        s.hasMore &&
        s.loadMoreError == null &&
        !s.loadingMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onLoadMore());
    }
    return itemBuilder(context, s.items[i]);
  }

  @override
  Widget build(BuildContext context) {
    return value.when(
      // A failed refresh keeps the rows already loaded (FRONTEND_SPEC).
      skipError: true,
      loading: () => const SkeletonList(),
      error: (_, _) => ErrorPanel(onRetry: onRetry),
      data: (s) {
        if (s.items.isEmpty) return empty;
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
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (gridDelegate == null)
                SliverList.builder(
                  itemCount: s.items.length,
                  itemBuilder: (context, i) => item(context, s, i),
                )
              else
                SliverPadding(
                  padding: gridPadding,
                  sliver: SliverGrid.builder(
                    gridDelegate: gridDelegate!,
                    itemCount: s.items.length,
                    itemBuilder: (context, i) => item(context, s, i),
                  ),
                ),
              // Always built, so the spinner runs only while a page loads.
              if (s.loadingMore || s.loadMoreError != null)
                SliverToBoxAdapter(
                  child: LoadMoreRow(
                    error: s.loadMoreError,
                    onRetry: onLoadMore,
                  ),
                ),
              // The last row scrolls clear of anything overlapping the
              // bottom edge (system insets, floating snack bars).
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 24 + MediaQuery.paddingOf(context).bottom,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
