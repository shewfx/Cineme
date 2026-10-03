import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../availability/data/availability_repository.dart';

/// "Where to watch" under the film's details: subscription services first,
/// then free; rent/buy as one muted, separately labelled line. Shows nothing
/// while loading, on failure, or when TMDB lists no providers for the region,
/// so the recommendation itself is never disturbed. With no streaming region
/// at all (a new account on a UTC profile) it asks once, quietly, for one
/// instead of staying silent. Providers are never invented.
class AvailabilitySection extends ConsumerWidget {
  const AvailabilitySection({
    super.key,
    required this.tmdbId,
    this.centered = false,
  });

  final int tmdbId;
  final bool centered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(movieAvailabilityProvider(tmdbId)).value;
    if (a == null) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    if (a.region == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: TextButton(
          key: const ValueKey('choose-region'),
          onPressed: () => context.go('/profile'),
          child: const Text(
            'Choose your streaming region to see where to watch',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (a.isEmpty) return const SizedBox.shrink();
    final muted = text.labelMedium?.copyWith(color: AppColors.textMuted);
    final watchNow = [...a.streaming, ...a.free];
    final paid = {
      for (final o in [...a.rent, ...a.buy]) o.name,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: centered
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          if (watchNow.isNotEmpty) ...[
            Text('Where to watch', style: muted),
            const SizedBox(height: 6),
            Wrap(
              alignment: centered ? WrapAlignment.center : WrapAlignment.start,
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final o in watchNow.take(4))
                  _ProviderChip(
                    offer: o,
                    free: a.free.contains(o) && !a.streaming.contains(o),
                  ),
              ],
            ),
          ],
          if (paid.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '${watchNow.isEmpty ? 'Rent or buy on' : 'Also to rent or buy on'} '
              '${paid.take(3).join(', ')}',
              textAlign: centered ? TextAlign.center : TextAlign.start,
              style: muted,
            ),
          ],
          const SizedBox(height: 4),
          // JustWatch attribution, required for TMDB watch-provider data.
          Text(
            'Streaming data: JustWatch · ${a.region}',
            textAlign: centered ? TextAlign.center : TextAlign.start,
            style: muted,
          ),
        ],
      ),
    );
  }
}

class _ProviderChip extends StatelessWidget {
  const _ProviderChip({required this.offer, required this.free});

  final ProviderOffer offer;
  final bool free;

  @override
  Widget build(BuildContext context) {
    final label = free ? '${offer.name} (free)' : offer.name;
    return Semantics(
      label: 'Available on $label',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 4, 10, 4),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox.square(
                dimension: 22,
                child: offer.logoUrl == null
                    ? const ColoredBox(color: AppColors.border)
                    : Image.network(
                        offer.logoUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            const ColoredBox(color: AppColors.border),
                      ),
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
