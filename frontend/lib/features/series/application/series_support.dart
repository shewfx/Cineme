import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/series.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/data/account_repository.dart';
import '../../history/application/history_controllers.dart';
import '../../today/application/today_controller.dart';
import '../data/series_repository.dart';

/// Whether this session can use shows: a series repository exists (not the
/// UI preview) and the backend reported the Tonight media preference, which
/// is how an older backend without shows is detected (ADR 011). When false,
/// every show-related control stays hidden and nothing changes for films.
final seriesEnabledProvider = Provider<bool>((ref) {
  if (ref.watch(seriesRepositoryProvider) == null) return false;
  return ref.watch(accountProvider).value?.tonightMedia != null;
});

/// What Tonight considers, saved on the server so every device agrees.
/// Changing it never touches history, the watchlist or progress; it only
/// clears an open pick (the server supersedes it without a replacement).
class TonightMediaController extends Notifier<TonightMedia?> {
  @override
  TonightMedia? build() => ref.watch(accountProvider).value?.tonightMedia;

  Future<void> set(TonightMedia media) async {
    await ref.read(accountRepositoryProvider)!.setTonightMedia(media);
    if (!ref.mounted) return;
    state = media;
    ref
      ..invalidate(todayEnvelopeProvider)
      ..invalidate(recommendationHistoryProvider);
  }
}

final tonightMediaProvider =
    NotifierProvider<TonightMediaController, TonightMedia?>(
      TonightMediaController.new,
    );
