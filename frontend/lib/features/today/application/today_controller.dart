import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/revision.dart';
import '../../../shared/models/session_context.dart';
import '../../../shared/models/today_state.dart';
import '../../../shared/models/viewing.dart';
import '../../history/application/history_controllers.dart';
import '../../history/data/history_repository.dart';
import '../data/today_repository.dart';

/// Which Today command is in flight; its button shows progress and the
/// others are disabled. The last envelope stays on screen meanwhile.
enum TodayAction { pick, save, accept, reject, watched, rate }

/// Tonight's context draft plus action progress.
class TodayViewState {
  const TodayViewState({
    this.desiredExperience,
    this.currentMood,
    this.maxRuntimeMinutes,
    this.carried,
    this.pick,
    this.busy,
  });

  final DesiredExperience? desiredExperience;
  final CurrentMood? currentMood;
  final int? maxRuntimeMinutes;

  /// Saved context whose other fields (tonight's avoided genres, lighter
  /// target) an edit keeps unchanged.
  final SessionContext? carried;

  /// Result of the last Pick/Save from a context screen.
  final AsyncValue<void>? pick;
  final TodayAction? busy;

  bool get canPick => desiredExperience != null && busy == null;

  SessionContext? get context {
    final intent = desiredExperience;
    if (intent == null) return null;
    final base = carried ?? SessionContext(desiredExperience: intent);
    return base.copyWith(
      desiredExperience: intent,
      currentMood: () => currentMood,
      maxRuntimeMinutes: () => maxRuntimeMinutes,
    );
  }

  TodayViewState copyWith({
    DesiredExperience? Function()? desiredExperience,
    CurrentMood? Function()? currentMood,
    int? Function()? maxRuntimeMinutes,
    AsyncValue<void>? Function()? pick,
    TodayAction? Function()? busy,
  }) => TodayViewState(
    desiredExperience: desiredExperience != null
        ? desiredExperience()
        : this.desiredExperience,
    currentMood: currentMood != null ? currentMood() : this.currentMood,
    maxRuntimeMinutes: maxRuntimeMinutes != null
        ? maxRuntimeMinutes()
        : this.maxRuntimeMinutes,
    carried: carried,
    pick: pick != null ? pick() : this.pick,
    busy: busy != null ? busy() : this.busy,
  );
}

class TodayController extends Notifier<TodayViewState> {
  @override
  TodayViewState build() => const TodayViewState();

  TodayRepository get _repo => ref.read(todayRepositoryProvider)!;

  /// Starts an edit from the saved context; Cancel re-seeds, changing nothing.
  void seedFrom(SessionContext? saved) => state = TodayViewState(
    desiredExperience: saved?.desiredExperience,
    currentMood: saved?.currentMood,
    maxRuntimeMinutes: saved?.maxRuntimeMinutes,
    carried: saved,
  );

  void selectDesiredExperience(DesiredExperience value) =>
      state = state.copyWith(desiredExperience: () => value);

  /// Tapping the selected mood clears it. Never touches desiredExperience.
  void toggleMood(CurrentMood value) => state = state.copyWith(
    currentMood: () => state.currentMood == value ? null : value,
  );

  void selectMaxRuntime(int? minutes) =>
      state = state.copyWith(maxRuntimeMinutes: () => minutes);

  /// Pick my movie / Pick with this context. Returns false when the server
  /// asks for a context review (paused, unchanged context).
  Future<bool> pickMyMovie() async {
    final context = state.context;
    if (context == null || !state.canPick) return true;
    var ok = true;
    await _run(TodayAction.pick, () async {
      try {
        _apply(await _repo.choose(context));
      } on TodayConflict catch (c) {
        if (c.code != 'CONTEXT_REVIEW_REQUIRED') rethrow;
        ok = false;
        ref.invalidate(todayEnvelopeProvider);
      }
    }, recordOnDraft: true);
    return ok;
  }

  /// Save without choosing. A mood-only change keeps tonight's pick.
  Future<void> saveContext() async {
    final context = state.context;
    if (context == null || state.busy != null) return;
    await _run(
      TodayAction.save,
      () async => _apply(await _repo.saveContext(context)),
      recordOnDraft: true,
    );
  }

  /// Deliberate Continue once after the pause: exactly one more film.
  Future<void> continueOnce(SessionContext saved) => _run(
    TodayAction.pick,
    () async => _apply(await _repo.choose(saved, continueAfterPause: true)),
  );

  Future<void> accept(Recommendation r) =>
      _run(TodayAction.accept, () async => _apply(await _repo.accept(r.id)));

  Future<ReplacementOutcome?> reject(
    Recommendation r,
    RejectReason reason, {
    int? maxRuntimeMinutes,
    Set<int> avoidGenreIds = const {},
    required bool chooseAnother,
  }) async {
    ReplacementOutcome? outcome;
    await _run(TodayAction.reject, () async {
      final result = await _repo.reject(
        r.id,
        reason,
        maxRuntimeMinutes: maxRuntimeMinutes,
        avoidGenreIds: avoidGenreIds,
        chooseAnother: chooseAnother,
      );
      outcome = result.outcome;
      _apply(result.today);
      if (reason == RejectReason.alreadyWatched ||
          reason == RejectReason.neverRecommend) {
        ref.read(inventoryRevisionProvider.notifier).bump();
      }
    });
    return outcome;
  }

  Future<void> markWatched(Recommendation r, {Rating? rating}) =>
      _run(TodayAction.watched, () async {
        _apply(await _repo.markWatched(r.id, rating: rating));
        ref.read(inventoryRevisionProvider.notifier).bump();
      });

  /// Post-watch rating: long-term taste evidence, replaced on edit.
  Future<void> rate(Viewing viewing, Rating? rating) =>
      _run(TodayAction.rate, () async {
        await ref
            .read(historyRepositoryProvider)!
            .rateViewing(viewing.id, rating);
        ref.invalidate(todayEnvelopeProvider);
        ref.read(inventoryRevisionProvider.notifier).bump();
      });

  void _apply(TodayEnvelope envelope) {
    if (!ref.mounted) return;
    ref.read(todayEnvelopeProvider.notifier).apply(envelope);
    ref.invalidate(recommendationHistoryProvider);
  }

  /// One command at a time. Failures rethrow so the screen can explain them
  /// while keeping the current card; nothing is applied optimistically.
  Future<void> _run(
    TodayAction action,
    Future<void> Function() body, {
    bool recordOnDraft = false,
  }) async {
    if (state.busy != null) return;
    state = state.copyWith(
      busy: () => action,
      pick: recordOnDraft ? () => const AsyncLoading() : null,
    );
    try {
      await body();
      if (ref.mounted) {
        state = state.copyWith(
          busy: () => null,
          pick: recordOnDraft ? () => const AsyncData(null) : null,
        );
      }
    } catch (e, st) {
      if (ref.mounted) {
        state = state.copyWith(
          busy: () => null,
          pick: recordOnDraft ? () => AsyncError(e, st) : null,
        );
      }
      if (!recordOnDraft) rethrow;
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
