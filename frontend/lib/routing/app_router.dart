import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_theme.dart';
import '../core/widgets/floating_nav_bar.dart';
import '../core/widgets/tab_swipe_exclusion.dart';
import '../features/auth/application/auth_controller.dart';
import '../features/auth/presentation/auth_pages.dart';
import '../features/history/presentation/history_page.dart';
import '../features/onboarding/presentation/onboarding_page.dart';
import '../features/movies/presentation/movie_details_page.dart';
import '../features/preferences/presentation/profile_page.dart';
import '../features/search/presentation/search_page.dart';
import '../features/series/presentation/series_details_page.dart';
import '../features/today/presentation/context_view.dart';
import '../features/today/presentation/today_page.dart';
import '../features/watchlist/presentation/watchlist_page.dart';
import '../shared/models/inventory.dart' show WatchlistEntry;

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
    // Browser URLs we do not own (for example a Supabase email-confirmation
    // redirect carrying `#access_token=...`) land on the app root, which also
    // replaces that address-bar fragment. Tokens in it are never used.
    onException: (context, state, router) => router.go('/today'),
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
      GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingPage()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => _AppShell(
          shell: shell,
          isRootTab: const {
            '/today',
            '/watchlist',
            '/history',
            '/profile',
          }.contains(state.uri.path),
        ),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/today', builder: (_, _) => const TodayPage()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/watchlist',
                builder: (_, _) => const WatchlistPage(),
              ),
              GoRoute(
                path: '/series/:tmdbId',
                builder: (context, state) {
                  final tmdbId = int.tryParse(
                    state.pathParameters['tmdbId'] ?? '',
                  );
                  if (tmdbId == null || tmdbId <= 0 || tmdbId > 2147483647) {
                    return const InvalidMovieDetailsPage();
                  }
                  return SeriesDetailsPage(tmdbId: tmdbId);
                },
              ),
              GoRoute(
                path: '/movies/:tmdbId',
                builder: (context, state) {
                  final tmdbId = int.tryParse(
                    state.pathParameters['tmdbId'] ?? '',
                  );
                  if (tmdbId == null || tmdbId <= 0 || tmdbId > 2147483647) {
                    return const InvalidMovieDetailsPage();
                  }
                  final extra = state.extra;
                  return MovieDetailsPage(
                    tmdbId: tmdbId,
                    entry: extra is WatchlistEntry ? extra : null,
                  );
                },
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/history', builder: (_, _) => const HistoryPage()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/profile', builder: (_, _) => const ProfilePage()),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/search',
        builder: (context, state) => SearchPage(
          logMode: state.uri.queryParameters['mode'] == 'log',
          initialShows: state.uri.queryParameters['media'] == 'shows',
        ),
      ),
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
const _gateRoutes = {
  ..._signedOutRoutes,
  '/starting',
  '/config',
  '/onboarding',
};

/// The private shell renders only for a signed-in user with a bootstrapped
/// profile; the preview build skips identity entirely.
String? authRedirect(AuthGate gate, String location) => switch (gate) {
  AuthGate.preview => _gateRoutes.contains(location) ? '/today' : null,
  AuthGate.configMissing => location == '/config' ? null : '/config',
  AuthGate.checkingSession ||
  AuthGate.settingUp => location == '/starting' ? null : '/starting',
  AuthGate.signedOut => _signedOutRoutes.contains(location) ? null : '/sign-in',
  AuthGate.confirmEmail => location == '/check-email' ? null : '/check-email',
  // New accounts finish (or Skip) onboarding before any private route.
  AuthGate.onboarding => location == '/onboarding' ? null : '/onboarding',
  AuthGate.ready => _gateRoutes.contains(location) ? '/today' : null,
};

class _AppShell extends StatefulWidget {
  const _AppShell({required this.shell, required this.isRootTab});

  final StatefulNavigationShell shell;
  final bool isRootTab;

  static const _swipeDistance = 72.0;

  @override
  State<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<_AppShell> {
  final _tabSwipeTracker = TabSwipeTracker();
  final _pointerStarts = <int, Offset>{};

  void _onPointerDown(PointerDownEvent event) {
    _pointerStarts[event.pointer] = event.position;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!widget.isRootTab ||
        _tabSwipeTracker.excludedPointers.contains(event.pointer)) {
      return;
    }
    final start = _pointerStarts[event.pointer];
    if (start == null) return;
    final delta = event.position - start;
    if (delta.dx.abs() < _AppShell._swipeDistance ||
        delta.dx.abs() <= delta.dy.abs() * 1.5) {
      return;
    }
    final next = (widget.shell.currentIndex + (delta.dx < 0 ? 1 : -1)).clamp(
      0,
      3,
    );
    if (next != widget.shell.currentIndex) widget.shell.goBranch(next);
    _pointerStarts.remove(event.pointer);
  }

  void _onPointerEnd(PointerEvent event) {
    _pointerStarts.remove(event.pointer);
    _tabSwipeTracker.excludedPointers.remove(event.pointer);
  }

  @override
  Widget build(BuildContext context) {
    final shell = widget.shell;
    // A floating pill, positioned with real layout (padding and the safe area),
    // never a paint-only translation: what you see is what you touch.
    return Scaffold(
      body: TabSwipeScope(
        tracker: _tabSwipeTracker,
        child: Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerEnd,
          onPointerCancel: _onPointerEnd,
          child: shell,
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 6, 28, 20),
          // Compact and constant-width on every screen, centred.
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: FloatingNavBar.maxWidth,
              ),
              child: DecoratedBox(
                key: const ValueKey('floating-nav'),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(32),
                  border: Border.all(color: AppColors.border),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 24,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: FloatingNavBar(
                  selectedIndex: shell.currentIndex,
                  // Re-tapping the current tab returns it to its first page.
                  onSelected: (i) => shell.goBranch(
                    i,
                    initialLocation: i == shell.currentIndex,
                  ),
                  tabs: const [
                    NavTab(
                      label: 'Tonight',
                      icon: Icons.movie_outlined,
                      selectedIcon: Icons.movie,
                    ),
                    NavTab(
                      label: 'Watchlist',
                      icon: Icons.bookmark_border,
                      selectedIcon: Icons.bookmark,
                    ),
                    NavTab(label: 'History', icon: Icons.history),
                    NavTab(
                      label: 'Profile',
                      icon: Icons.person_outline,
                      selectedIcon: Icons.person,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
