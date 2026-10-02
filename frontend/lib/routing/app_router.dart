import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/today/presentation/today_page.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: '/today',
    routes: [
      GoRoute(path: '/today', builder: (context, state) => const TodayPage()),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
