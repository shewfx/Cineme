import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../availability/data/availability_repository.dart';

/// "Available on" under the film's details: subscription services first,
/// then free; rent/buy as one muted line. Shows nothing while loading, on
/// failure, when the region is unknown or when TMDB lists no providers, so
/// the recommendation itself is never disturbed.
class AvailabilitySection extends ConsumerWidget {
  const AvailabilitySection({super.key, required this.tmdbId});

  final int tmdbId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(movieAvailabilityProvider(tmdbId)).value;
    if (a == null || a.region == null || a.isEmpty) {
      return const SizedBox.shrink();
    }
    final text = Theme.of(context).textTheme;
    final muted = text.labelMedium?.copyWith(color: AppColors.textMuted);
    final watchNow = [...a.streaming, ...a.free];
    final paid = {
      for (final o in [...a.rent, ...a.buy]) o.name,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (watchNow.isNotEmpty) ...[
            Text('Available on', style: muted),
            const SizedBox(height: 6),
            Wrap(
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
              style: muted,
            ),
          ],
          const SizedBox(height: 4),
          // JustWatch attribution, required for TMDB watch-provider data.
          Text('Streaming data: JustWatch · ${a.region}', style: muted),
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
