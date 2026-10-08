import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The details-page frame shared by films and shows: a transparent app bar
/// over the poster's enlarged, blurred and darkened artwork that fades into
/// the app background, the scrolling [body], and an optional pinned
/// [actions] bar. Missing artwork keeps the plain background.
class DetailsBackdropScaffold extends StatelessWidget {
  const DetailsBackdropScaffold({
    super.key,
    required this.title,
    required this.body,
    this.posterUrl,
    this.actions,
  });

  final String title;
  final String? posterUrl;
  final Widget body;
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    final url = posterUrl;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(title),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: AppColors.background),
          if (url != null && url.isNotEmpty) PosterBackdrop(url: url),
          SafeArea(
            top: false,
            bottom: false,
            child: Column(
              children: [
                SizedBox(
                  height: MediaQuery.paddingOf(context).top + kToolbarHeight,
                ),
                Expanded(child: body),
                ?actions,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The blurred, darkened poster behind a details page. Network failure falls
/// back to nothing (the background shows through).
class PosterBackdrop extends StatelessWidget {
  const PosterBackdrop({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight * 0.80;
        return Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: height,
              child: ClipRect(
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 13, sigmaY: 13),
                  child: Image.network(
                    url,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                    cacheWidth:
                        (constraints.maxWidth *
                                MediaQuery.devicePixelRatioOf(context))
                            .round(),
                    errorBuilder: (_, _, _) => const SizedBox.expand(),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: height,
              child: const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0, 0.48, 0.67, 0.84, 1],
                      colors: [
                        Color(0x77000000),
                        Color(0x99000000),
                        Color(0xD91C1C1C),
                        Color(0xF51C1C1C),
                        AppColors.background,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// A text-and-icon action in the pinned bar of a details page.
class DetailActionButton extends StatelessWidget {
  const DetailActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: onPressed,
    icon: Icon(icon, size: 18),
    label: Text(label),
    style: TextButton.styleFrom(
      foregroundColor: AppColors.textSoft,
      minimumSize: const Size(48, 48),
    ),
  );
}

/// A muted state line in the pinned bar ("Removed from watchlist").
class DetailStatusLine extends StatelessWidget {
  const DetailStatusLine(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
    child: Text(
      label,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(color: AppColors.textMuted),
    ),
  );
}

/// The pinned actions bar: centered, wrapping, clear of the safe area.
class DetailActionsBar extends StatelessWidget {
  const DetailActionsBar({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 4,
          runSpacing: 0,
          children: children,
        ),
      ),
    );
  }
}

/// Placeholder while a details page loads (poster, title lines, overview).
class DetailsLoadingSkeleton extends StatelessWidget {
  const DetailsLoadingSkeleton({super.key});

  @override
  Widget build(BuildContext context) => ListView(
    physics: const NeverScrollableScrollPhysics(),
    padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 108,
            height: 162,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          const SizedBox(width: 20),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonLine(width: 170, height: 24),
                SizedBox(height: 12),
                SkeletonLine(width: 112),
                SizedBox(height: 9),
                SkeletonLine(width: 140),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 28),
      const SkeletonLine(width: 92),
      const SizedBox(height: 12),
      const SkeletonLine(),
      const SizedBox(height: 8),
      const SkeletonLine(width: 260),
      const SizedBox(height: 8),
      const SkeletonLine(width: 210),
      const SizedBox(height: 26),
      const Center(child: CircularProgressIndicator(strokeWidth: 2)),
    ],
  );
}

class SkeletonLine extends StatelessWidget {
  const SkeletonLine({
    super.key,
    this.width = double.infinity,
    this.height = 12,
  });

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(6),
    ),
  );
}
