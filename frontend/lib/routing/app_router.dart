import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_theme.dart';
import '../features/auth/application/auth_controller.dart';
import '../features/auth/presentation/auth_pages.dart';
import '../features/history/presentation/history_page.dart';
import '../features/preferences/presentation/profile_page.dart';
import '../features/search/presentation/search_page.dart';
import '../features/today/presentation/context_view.dart';
import '../features/today/presentation/today_page.dart';
import '../features/watchlist/presentation/watchlist_page.dart';

/// Four tabs (stateful, so each keeps its scroll position). Search is a
/// nested full-screen destination, not a fifth tab.
final appRouterProvider = Provider<GoRouter>((ref) {
  // Re-run redirects whenever sign-in or profile setup state changes.
  final refresh = ValueNotifier<int>(0);
  ref
    ..listen(authGateProvider, (_, _) => refresh.value++)
    ..onDispose(refresh.dispose);
  final router = GoRouter(
    initialLocation: '/today',
    refreshListenable: refresh,
    redirect: (context, state) =>
        authRedirect(ref.read(authGateProvider), state.matchedLocation),
    routes: [
      GoRoute(path: '/sign-in', builder: (_, _) => const SignInPage()),
      GoRoute(path: '/sign-up', builder: (_, _) => const SignUpPage()),
      GoRoute(
        path: '/check-email',
        builder: (_, state) =>
            CheckEmailPage(email: state.uri.queryParameters['email']),
      ),
      GoRoute(path: '/starting', builder: (_, _) => const StartingPage()),
      GoRoute(path: '/config', builder: (_, _) => const ConfigMissingPage()),
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
      GoRoute(
        path: '/today/context',
        builder: (context, state) => const EditTonightPage(),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

const _signedOutRoutes = {'/sign-in', '/sign-up', '/check-email'};
const _gateRoutes = {..._signedOutRoutes, '/starting', '/config'};

/// The private shell renders only for a signed-in user with a bootstrapped
/// profile; the preview build skips identity entirely.
String? authRedirect(AuthGate gate, String location) => switch (gate) {
  AuthGate.preview => _gateRoutes.contains(location) ? '/today' : null,
  AuthGate.configMissing => location == '/config' ? null : '/config',
  AuthGate.checkingSession ||
  AuthGate.settingUp => location == '/starting' ? null : '/starting',
  AuthGate.signedOut => _signedOutRoutes.contains(location) ? null : '/sign-in',
  AuthGate.confirmEmail => location == '/check-email' ? null : '/check-email',
  AuthGate.ready => _gateRoutes.contains(location) ? '/today' : null,
};

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
