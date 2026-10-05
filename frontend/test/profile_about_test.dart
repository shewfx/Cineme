import 'package:cineme/features/preferences/application/profile_controller.dart';
import 'package:cineme/features/preferences/data/profile_repository.dart';
import 'package:cineme/features/preferences/presentation/profile_page.dart';
import 'package:cineme/shared/models/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Cinemé',
      packageName: 'dev.cineme.cineme',
      version: '9.8.7-test',
      buildNumber: '23',
      buildSignature: '',
    );
  });

  testWidgets('Profile About shows package version and build commit', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileRepositoryProvider.overrideWithValue(
            _EmptyProfileRepository(),
          ),
          profileProvider.overrideWith((ref) async => _profile),
        ],
        child: const MaterialApp(home: ProfilePage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Movie data'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();

    const sourceCommit = String.fromEnvironment(
      'SOURCE_COMMIT',
      defaultValue: 'Development',
    );
    expect(find.text('Cinemé v9.8.7-test'), findsOneWidget);
    expect(find.text('Build $sourceCommit'), findsOneWidget);
  });
}

const _profile = Profile(
  displayName: null,
  timezone: 'UTC',
  preferredGenres: [],
  blockedGenres: [],
  defaultMaxRuntimeMinutes: null,
  aiContextEnabled: false,
  blockedMovies: [],
);

class _EmptyProfileRepository implements ProfileRepository {
  @override
  Future<Profile> profile() async => _profile;

  @override
  Future<void> block(int tmdbId) async {}

  @override
  Future<void> unblock(int tmdbId) async {}
}
