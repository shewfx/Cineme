import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cineme/app.dart';
import 'package:cineme/core/config/app_config.dart';
import 'package:cineme/core/network/api_client.dart';
import 'package:cineme/features/auth/data/account_repository.dart';
import 'package:cineme/features/auth/data/auth_repository.dart';
import 'package:cineme/features/preferences/data/profile_repository.dart';
import 'package:cineme/preview/preview_store.dart';
import 'package:cineme/shared/models/profile.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_finders.dart';

const config = AppConfig(
  apiBaseUrl: 'http://10.0.2.2:8000',
  supabaseUrl: 'https://test-project.supabase.co',
  supabasePublishableKey: 'sb_publishable_test',
);

/// Scripted stand-in for the Supabase SDK boundary.
class FakeAuth implements AuthRepository {
  FakeAuth([this._user]);

  AuthUser? _user;
  final _changes = StreamController<AuthUser?>.broadcast();
  int signOuts = 0;
  bool failSignOutNetwork = false;
  SignUpOutcome signUpOutcome = SignUpOutcome.confirmEmail;
  AuthFailure? signInFailure;

  void emit(AuthUser? user) {
    _user = user;
    _changes.add(user);
  }

  @override
  AuthUser? get currentUser => _user;

  @override
  Stream<AuthUser?> userChanges() async* {
    yield _user;
    yield* _changes.stream;
  }

  @override
  Future<String?> accessToken() async =>
      _user == null ? null : 'token-${_user!.id}';

  @override
  Future<void> signIn(String email, String password) async {
    if (signInFailure != null) throw signInFailure!;
    emit(AuthUser(id: 'user-$email', email: email));
  }

  @override
  Future<SignUpOutcome> signUp(String email, String password) async =>
      signUpOutcome;

  @override
  Future<void> signOut() async {
    signOuts++;
    emit(null); // local credentials always cleared, even if revoke fails
  }
}

/// Per-user server state, so account switches can be checked for leaks.
class FakeAccount implements AccountRepository {
  @override
  Future<void> setRegion(String? countryCode) async {}

  @override
  Future<List<(String, String)>> regions() async => const [('IN', 'India')];

  FakeAccount(this.auth);

  final FakeAuth auth;
  final calls = <String>[];
  final names = <String, String>{};
  ApiError? failBootstrap;

  String get _uid => auth.currentUser!.id;

  @override
  Future<void> bootstrap() async {
    calls.add('bootstrap:$_uid');
    if (failBootstrap != null) throw failBootstrap!;
  }

  @override
  Future<Profile> me() async {
    calls.add('me:$_uid');
    return Profile(
      displayName: names[_uid],
      timezone: 'UTC',
      preferredGenres: const [],
      blockedGenres: const [],
      defaultMaxRuntimeMinutes: null,
      aiContextEnabled: false,
      blockedMovies: null,
    );
  }
}

class Rig {
  Rig({AuthUser? signedIn}) : auth = FakeAuth(signedIn) {
    account = FakeAccount(auth);
  }

  final FakeAuth auth;
  late final FakeAccount account;

  Widget app({AppConfig appConfig = config}) => ProviderScope(
    retry: noAutomaticRetry,
    overrides: [
      appConfigProvider.overrideWithValue(appConfig),
      authRepositoryProvider.overrideWithValue(auth),
      accountRepositoryProvider.overrideWithValue(account),
      profileRepositoryProvider.overrideWithValue(
        AccountProfileRepository(account),
      ),
    ],
    child: const CinemeApp(),
  );
}

const alice = AuthUser(id: 'alice', email: 'alice@example.test');
const bob = AuthUser(id: 'bob', email: 'bob@example.test');

Future<void> goProfile(WidgetTester tester) async {
  await tester.tap(navTab('Profile'));
  await tester.pumpAndSettle();
}

void main() {
  group('Auth routing', () {
    testWidgets('signed out: sign-in screen, no private shell', (tester) async {
      final rig = Rig();
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      expect(find.text('Sign in'), findsWidgets);
      expect(find.byType(FloatingNavBar), findsNothing);
      expect(rig.account.calls, isEmpty);
    });

    testWidgets('sign-in bootstraps, then reads /me, then shows the shell', (
      tester,
    ) async {
      final rig = Rig();
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Email'),
        'a@example.test',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Password'),
        'correct-horse',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(rig.account.calls, [
        'bootstrap:user-a@example.test',
        'me:user-a@example.test',
      ]);
      expect(find.byType(FloatingNavBar), findsOneWidget);
      // Tonight has no real repository until P4: honest, no fake movie.
      expect(
        find.text("Tonight's pick is not available in this build yet."),
        findsOneWidget,
      );
    });

    testWidgets('sign-in failure is shown and keeps the user signed out', (
      tester,
    ) async {
      final rig = Rig()
        ..auth.signInFailure = const AuthFailure(
          'Email or password is incorrect.',
        );
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Email'),
        'a@example.test',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Password'),
        'wrong-password',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Email or password is incorrect.'), findsOneWidget);
      expect(find.byType(FloatingNavBar), findsNothing);
    });

    testWidgets('restored session goes straight to setup, then the shell', (
      tester,
    ) async {
      final rig = Rig(signedIn: alice);
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      expect(rig.account.calls, ['bootstrap:alice', 'me:alice']);
      expect(find.byType(FloatingNavBar), findsOneWidget);
    });

    testWidgets('setup failure offers Retry and keeps the session', (
      tester,
    ) async {
      final rig = Rig(signedIn: alice)
        ..account.failBootstrap = const ApiError(
          status: 503,
          code: 'DEPENDENCY_UNAVAILABLE',
          message: 'Sign-in service is unavailable. Try again shortly.',
          retryable: true,
        );
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();

      expect(find.text("Couldn't finish signing in"), findsOneWidget);
      expect(
        find.text('Sign-in service is unavailable. Try again shortly.'),
        findsOneWidget,
      );
      expect(
        find.byType(FloatingNavBar),
        findsNothing,
        reason: 'no fake success',
      );
      expect(
        rig.auth.signOuts,
        0,
        reason: 'infrastructure errors do not sign out',
      );

      rig.account.failBootstrap = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byType(FloatingNavBar), findsOneWidget);
    });

    testWidgets('unconfirmed email goes to Check your email', (tester) async {
      final rig = Rig(signedIn: alice)
        ..account.failBootstrap = const ApiError(
          status: 403,
          code: 'EMAIL_NOT_VERIFIED',
          message: 'Confirm your email address, then try again.',
        );
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      expect(find.text('Check your email'), findsOneWidget);
      expect(find.byType(FloatingNavBar), findsNothing);
    });

    testWidgets('sign-up needing confirmation shows Check your email', (
      tester,
    ) async {
      final rig = Rig();
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create an account'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Email'),
        'new@example.test',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Password'),
        'long-enough',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pumpAndSettle();
      expect(find.text('Check your email'), findsOneWidget);
      expect(find.textContaining('new@example.test'), findsOneWidget);
    });

    testWidgets(
      'sign out returns to sign-in and an account switch never leaks',
      (tester) async {
        final rig = Rig(signedIn: alice);
        rig.account.names
          ..['alice'] = 'Alice'
          ..['bob'] = 'Bob';
        await tester.pumpWidget(rig.app());
        await tester.pumpAndSettle();
        await goProfile(tester);
        expect(find.text('Alice'), findsOneWidget);

        await tester.scrollUntilVisible(
          find.text('Sign out'),
          300,
          scrollable: find.byType(Scrollable).last,
        );
        expect(find.text('alice@example.test'), findsOneWidget);
        await tester.ensureVisible(find.text('Sign out'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sign out'));
        await tester.pumpAndSettle();
        expect(rig.auth.signOuts, 1);
        expect(find.text('Sign in'), findsWidgets);
        expect(find.text('Alice'), findsNothing);

        rig.auth.emit(bob);
        await tester.pumpAndSettle();
        await goProfile(tester);
        expect(find.text('Bob'), findsOneWidget);
        expect(find.text('Alice'), findsNothing);
        expect(rig.account.calls.where((c) => c.endsWith(':bob')), isNotEmpty);
      },
    );

    testWidgets('normal build without configuration shows no fake data', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          retry: noAutomaticRetry,
          overrides: [
            appConfigProvider.overrideWithValue(AppConfig.fromEnvironment),
          ],
          child: const CinemeApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('This build is not configured'), findsOneWidget);
      expect(find.textContaining('SUPABASE_URL'), findsOneWidget);
      expect(find.byType(FloatingNavBar), findsNothing);
    });

    testWidgets('preview build never asks for sign-in', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          retry: noAutomaticRetry,
          overrides: previewOverrides(PreviewStore(latency: Duration.zero)),
          child: const CinemeApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('What do you want from tonight?'), findsOneWidget);
      expect(find.text('Sign in'), findsNothing);
    });
  });

  group('ApiClient', () {
    ApiClient client(_Adapter adapter, {String? token = 'tok'}) {
      final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
        ..httpClientAdapter = adapter;
      return ApiClient(dio, () async => token);
    }

    test('attaches the bearer token and idempotency key', () async {
      final adapter = _Adapter(200, {'ok': true});
      await client(
        adapter,
      ).patch('/api/v1/me', body: {'display_name': 'A'}, idempotencyKey: 'k-1');
      expect(adapter.last!.headers['Authorization'], 'Bearer tok');
      expect(adapter.last!.headers['Idempotency-Key'], 'k-1');
      expect(adapter.last!.method, 'PATCH');
    });

    test('sends no Authorization header without a session', () async {
      final adapter = _Adapter(200, {'ok': true});
      await client(adapter, token: null).get('/api/v1/me');
      expect(adapter.last!.headers.containsKey('Authorization'), isFalse);
    });

    test('maps the error envelope to ApiError', () async {
      final adapter = _Adapter(409, {
        'error': {
          'code': 'PROFILE_NOT_INITIALIZED',
          'message': 'Your Cinemé profile is not set up yet.',
          'details': {},
          'retryable': false,
        },
        'request_id': 'r1',
      });
      await expectLater(
        client(adapter).get('/api/v1/me'),
        throwsA(
          isA<ApiError>()
              .having((e) => e.status, 'status', 409)
              .having((e) => e.code, 'code', 'PROFILE_NOT_INITIALIZED'),
        ),
      );
    });

    test(
      'a non-envelope error body is a visible malformed-response error',
      () async {
        await expectLater(
          client(_Adapter(502, '<html>bad gateway</html>')).get('/api/v1/me'),
          throwsA(
            isA<ApiError>().having((e) => e.code, 'code', 'MALFORMED_RESPONSE'),
          ),
        );
      },
    );

    test(
      'profile JSON with missing fields is an error, not an empty profile',
      () {
        expect(
          () => profileFromJson({'id': 'x', 'timezone': 'UTC'}),
          throwsA(isA<ApiError>()),
        );
        final p = profileFromJson({
          'id': 'x',
          'display_name': null,
          'timezone': 'Asia/Kolkata',
          'created_at': '2026-10-01T22:00:00Z',
          'preferences': {
            'version': 1,
            'genre_preferences': <String, dynamic>{},
            'blocked_genre_ids': <int>[],
            'default_max_runtime_minutes': null,
            'ai_context_enabled': false,
          },
        });
        expect(p.timezone, 'Asia/Kolkata');
        expect(
          p.blockedMovies,
          isNull,
          reason: 'blocks are not available before P5',
        );
      },
    );
  });
}

/// Minimal Dio adapter returning one canned JSON (or text) response.
class _Adapter implements HttpClientAdapter {
  _Adapter(this.status, this.body);

  final int status;
  final Object body;
  RequestOptions? last;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    last = options;
    final isJson = body is! String;
    return ResponseBody.fromString(
      isJson ? jsonEncode(body) : body as String,
      status,
      headers: {
        Headers.contentTypeHeader: [isJson ? 'application/json' : 'text/html'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
