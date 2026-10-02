import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_theme.dart';
import '../features/history/presentation/history_page.dart';
import '../features/preferences/presentation/profile_page.dart';
import '../features/search/presentation/search_page.dart';
import '../features/today/presentation/today_page.dart';
import '../features/watchlist/presentation/watchlist_page.dart';

/// Four tabs (stateful, so each keeps its scroll position). Search is a
/// nested full-screen destination, not a fifth tab.
final appRouterProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: '/today',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => _AppShell(shell: shell),
        branches: [
          for (final (path, page) in [
            ('/today', const TodayPage()),
            ('/watchlist', const WatchlistPage()),
            ('/history', const HistoryPage()),
            ('/profile', const ProfilePage()),
          ])
            StatefulShellBranch(
              routes: [GoRoute(path: path, builder: (context, state) => page)],
            ),
        ],
      ),
      GoRoute(path: '/search', builder: (context, state) => const SearchPage()),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

class _AppShell extends StatelessWidget {
  const _AppShell({required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: shell,
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: NavigationBar(
          selectedIndex: shell.currentIndex,
          // Re-tapping the current tab returns it to its first page.
          onDestinationSelected: (i) =>
              shell.goBranch(i, initialLocation: i == shell.currentIndex),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.movie_outlined),
              selectedIcon: Icon(Icons.movie),
              label: 'Tonight',
            ),
            NavigationDestination(
              icon: Icon(Icons.bookmark_border),
              selectedIcon: Icon(Icons.bookmark),
              label: 'Watchlist',
            ),
            NavigationDestination(icon: Icon(Icons.history), label: 'History'),
            NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}
