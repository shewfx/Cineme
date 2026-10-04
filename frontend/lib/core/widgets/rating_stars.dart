import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../../shared/models/viewing.dart';

/// Shared five-star display used by selectors and read-only history rows.
class RatingStars extends StatelessWidget {
  const RatingStars({super.key, required this.rating, this.size = 22});

  final Rating? rating;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (rating == null) {
      return const Text(
        'Not rated',
        style: TextStyle(color: AppColors.textMuted),
      );
    }
    return Semantics(
      label: '${rating!.value} out of 5',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 1; i <= 5; i++)
              Icon(
                i <= rating!.value
                    ? Icons.star_rounded
                    : Icons.star_outline_rounded,
                size: size,
                color: i <= rating!.value
                    ? AppColors.accent
                    : AppColors.textMuted,
              ),
          ],
        ),
      ),
    );
  }
}

class FiveStarSelector extends StatelessWidget {
  const FiveStarSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final Rating? value;
  final ValueChanged<Rating>? onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = value?.value ?? 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: 'Rating',
          value: selected == 0 ? 'Not rated' : '$selected out of 5',
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 1; i <= 5; i++)
                Semantics(
                  button: true,
                  selected: selected == i,
                  label: '$i ${i == 1 ? 'star' : 'stars'}',
                  child: IconButton(
                    tooltip: '$i out of 5',
                    onPressed: onChanged == null
                        ? null
                        : () => onChanged!(Rating.values[i - 1]),
                    iconSize: 42,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      i <= selected
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      color: i <= selected
                          ? AppColors.accent
                          : AppColors.textMuted,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Text(
          selected == 0 ? 'Not rated' : '$selected out of 5',
          key: const ValueKey('rating-value'),
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: AppColors.textMuted),
        ),
      ],
    );
  }
}
