import 'package:flutter/material.dart';

/// P0 placeholder. The context-first one-movie flow arrives in P1.
class TodayPage extends StatelessWidget {
  const TodayPage({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Cinemé', style: textTheme.displayMedium),
                const SizedBox(height: 12),
                Text('One movie. No scrolling.', style: textTheme.titleMedium),
                const SizedBox(height: 32),
                Text(
                  "Tonight's pick is not available in this build yet.",
                  style: textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
