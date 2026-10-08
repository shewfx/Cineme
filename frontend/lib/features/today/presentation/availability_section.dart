import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../shared/models/series.dart' show MediaType;
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
    this.mediaType = MediaType.movie,
    this.detailed = false,
  });

  final int tmdbId;
  final bool centered;

  /// Movie and TV ids overlap, so the media type is part of the identity.
  final MediaType mediaType;

  /// Details pages show loading, retry and "unavailable" states; the Tonight
  /// card stays silent in those cases so the pick is never disturbed.
  final bool detailed;

  static const showNote =
      'Availability is for the show as a whole. A particular season or '
      'episode may differ.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = availabilityProvider(AvailabilityKey(mediaType, tmdbId));
    final state = ref.watch(provider);
    final a = state.value;
    final text = Theme.of(context).textTheme;
    final muted = text.labelMedium?.copyWith(color: AppColors.textMuted);
    if (a == null) {
      if (!detailed || ref.watch(availabilityRepositoryProvider) == null) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: state.hasError
            ? Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  Text("Couldn't load where to watch.", style: muted),
                  TextButton(
                    key: const ValueKey('availability-retry'),
                    onPressed: () => ref.invalidate(provider),
                    child: const Text('Retry'),
                  ),
                ],
              )
            : Semantics(
                label: 'Loading where to watch',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text('Checking where to watch…', style: muted),
                  ],
                ),
              ),
      );
    }
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
    if (a.isEmpty) {
      return detailed
          ? Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'No streaming information for ${a.region} right now.',
                key: const ValueKey('availability-unavailable'),
                style: muted,
              ),
            )
          : const SizedBox.shrink();
    }
    final watchNow = [...a.streaming, ...a.free];
    final visibleOffers = <_ProviderChoice>[];
    final seenOfferNames = <String>{};
    for (final offer in a.streaming) {
      if (seenOfferNames.add(offer.name.toLowerCase())) {
        visibleOffers.add(_ProviderChoice(offer, false));
      }
    }
    for (final offer in a.free) {
      if (seenOfferNames.add(offer.name.toLowerCase())) {
        visibleOffers.add(_ProviderChoice(offer, true));
      }
    }
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
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Where to watch', style: muted),
              // Required attribution lives here, one tap away, instead of
              // taking permanent space on the card.
              IconButton(
                key: const ValueKey('availability-info'),
                tooltip: 'About streaming data',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 36),
                padding: EdgeInsets.zero,
                color: AppColors.textMuted,
                icon: const Icon(Icons.info_outline),
                onPressed: () => showAvailabilityInfo(
                  context,
                  a.region!,
                  note: mediaType == MediaType.series ? showNote : null,
                ),
              ),
            ],
          ),
          if (watchNow.isNotEmpty) ...[
            _WatchNowProviders(
              key: ValueKey(tmdbId),
              offers: visibleOffers,
              centered: centered,
            ),
          ],
          if (paid.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '${watchNow.isEmpty ? 'Rent or buy on' : 'Also to rent or buy on'} '
              '${paid.join(', ')}',
              textAlign: centered ? TextAlign.center : TextAlign.start,
              style: muted,
            ),
          ],
          if (mediaType == MediaType.series) ...[
            const SizedBox(height: 6),
            Text(
              showNote,
              key: const ValueKey('availability-show-note'),
              textAlign: centered ? TextAlign.center : TextAlign.start,
              style: muted,
            ),
          ],
        ],
      ),
    );
  }
}

class _ProviderChoice {
  const _ProviderChoice(this.offer, this.free);

  final ProviderOffer offer;
  final bool free;
}

class _WatchNowProviders extends StatefulWidget {
  const _WatchNowProviders({
    super.key,
    required this.offers,
    required this.centered,
  });

  final List<_ProviderChoice> offers;
  final bool centered;

  @override
  State<_WatchNowProviders> createState() => _WatchNowProvidersState();
}

class _WatchNowProvidersState extends State<_WatchNowProviders> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final ordered = widget.offers.asMap().entries.toList()
      ..sort((a, b) {
        final priority = _providerPriority(a.value.offer.name)
            .compareTo(_providerPriority(b.value.offer.name));
        return priority == 0 ? a.key.compareTo(b.key) : priority;
      });
    final shown = _expanded ? ordered : ordered.take(3).toList();
    final hiddenCount = ordered.length - shown.length;

    return Wrap(
      alignment: widget.centered ? WrapAlignment.center : WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final entry in shown)
          _ProviderChip(offer: entry.value.offer, free: entry.value.free),
        if (hiddenCount > 0)
          TextButton(
            key: const ValueKey('availability-more-providers'),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: () => setState(() => _expanded = true),
            child: Text('+$hiddenCount more'),
          ),
        if (_expanded && ordered.length > 3)
          TextButton(
            onPressed: () => setState(() => _expanded = false),
            child: const Text('Show less'),
          ),
      ],
    );
  }
}

int _providerPriority(String name) {
  final normalized = name.toLowerCase();
  if (normalized.contains('netflix')) return 0;
  if (normalized.contains('prime video')) return 1;
  if (normalized.contains('jiohotstar') || normalized.contains('hotstar')) {
    return 2;
  }
  if (normalized.contains('apple tv')) return 3;
  return 4;
}

/// The JustWatch/TMDB attribution, shown on demand.
Future<void> showAvailabilityInfo(
  BuildContext context,
  String region, {
  String? note,
}) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  backgroundColor: AppColors.surface,
  showDragHandle: true,
  builder: (sheet) {
    final text = Theme.of(sheet).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text('Streaming data', style: text.titleLarge),
            ),
            const SizedBox(height: 12),
            Text(
              'Streaming availability data provided by JustWatch. '
              'Availability may vary by region.',
              style: text.bodyLarge?.copyWith(color: AppColors.textSoft),
            ),
            const SizedBox(height: 10),
            Text(
              'Showing the $region catalogue. You can change your '
              'streaming region in Profile.',
              style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
            ),
            if (note != null) ...[
              const SizedBox(height: 10),
              Text(
                note,
                style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  },
);

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
