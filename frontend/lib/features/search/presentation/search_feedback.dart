import 'package:flutter/material.dart';

import '../../../core/widgets/state_views.dart';
import '../application/search_controller.dart';

/// The one snack bar every Add / Already watched action reports through, so
/// search rows and the onboarding grid say the same thing.
void showSearchOutcome(
  ScaffoldMessengerState messenger,
  SearchOutcome outcome,
  String title,
) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(switch (outcome) {
          SearchOutcome.added => 'Added “$title” to your watchlist.',
          SearchOutcome.alreadySaved =>
            '“$title” is already in your watchlist.',
          SearchOutcome.alreadyWatched =>
            "You've already watched “$title”, so it isn't added.",
          SearchOutcome.ineligible => "“$title” can't be added.",
          SearchOutcome.blocked =>
            "You chose never to recommend “$title”. Unblock it in Profile first.",
          SearchOutcome.recorded => 'Recorded “$title” as watched.',
          SearchOutcome.alreadyRecorded =>
            '“$title” was already in your history.',
          SearchOutcome.failed => connectionErrorMessage,
        }),
      ),
    );
}
