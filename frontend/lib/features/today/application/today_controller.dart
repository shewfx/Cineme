import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/session_context.dart';
import '../../../shared/models/today_state.dart';
import '../../history/application/history_controllers.dart';
import '../data/today_repository.dart';

/// Tonight's context draft plus the result of the single explicit pick.
class TodayViewState {
  const TodayViewState({
    this.desiredExperience,
    this.currentMood,
    this.maxRuntimeMinutes,
    this.pick,
  });

  final DesiredExperience? desiredExperience;
  final CurrentMood? currentMood;
  final int? maxRuntimeMinutes;

  /// Null until "Pick my movie" is pressed.
  final AsyncValue<TodayEnvelope>? pick;

  bool get canPick => desiredExperience != null && !(pick?.isLoading ?? false);

  TodayViewState copyWith({
    DesiredExperience? Function()? desiredExperience,
    CurrentMood? Function()? currentMood,
    int? Function()? maxRuntimeMinutes,
    AsyncValue<TodayEnvelope>? Function()? pick,
  }) => TodayViewState(
    desiredExperience: desiredExperience != null
        ? desiredExperience()
        : this.desiredExperience,
    currentMood: currentMood != null ? currentMood() : this.currentMood,
    maxRuntimeMinutes: maxRuntimeMinutes != null
        ? maxRuntimeMinutes()
        : this.maxRuntimeMinutes,
    pick: pick != null ? pick() : this.pick,
  );
}

class TodayController extends Notifier<TodayViewState> {
  @override
  TodayViewState build() => const TodayViewState();

  void selectDesiredExperience(DesiredExperience value) =>
      state = state.copyWith(desiredExperience: () => value);

  /// Tapping the selected mood clears it. Never touches desiredExperience.
  void toggleMood(CurrentMood value) => state = state.copyWith(
    currentMood: () => state.currentMood == value ? null : value,
  );

  void selectMaxRuntime(int? minutes) =>
      state = state.copyWith(maxRuntimeMinutes: () => minutes);

  Future<void> pickMyMovie() async {
    final intent = state.desiredExperience;
    final repository = ref.read(todayRepositoryProvider);
    if (intent == null || repository == null || !state.canPick) return;
    final context = SessionContext(
      desiredExperience: intent,
      currentMood: state.currentMood,
      maxRuntimeMinutes: state.maxRuntimeMinutes,
    );
    state = state.copyWith(pick: () => const AsyncLoading());
    final result = await AsyncValue.guard(() => repository.choose(context));
    if (!ref.mounted) return;
    state = state.copyWith(pick: () => result);
    if (result case AsyncData(:final value)) {
      ref.read(todayEnvelopeProvider.notifier).apply(value);
      ref.invalidate(recommendationHistoryProvider);
    }
  }
}

/// Server-authoritative Today (GET /today). Reloading only reads; it never
/// chooses another movie.
class TodayEnvelopeController extends AsyncNotifier<TodayEnvelope> {
  @override
  Future<TodayEnvelope> build() => ref.read(todayRepositoryProvider)!.today();

  /// Applies the envelope returned by a Today mutation.
  void apply(TodayEnvelope envelope) => state = AsyncData(envelope);
}

final todayEnvelopeProvider =
    AsyncNotifierProvider<TodayEnvelopeController, TodayEnvelope>(
      TodayEnvelopeController.new,
    );

final todayControllerProvider =
    NotifierProvider<TodayController, TodayViewState>(TodayController.new);
