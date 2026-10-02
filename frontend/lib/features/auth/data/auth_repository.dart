import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The signed-in Supabase identity, as the app needs it.
class AuthUser {
  const AuthUser({required this.id, required this.email});

  final String id;
  final String email;

  @override
  bool operator ==(Object other) =>
      other is AuthUser && other.id == id && other.email == email;

  @override
  int get hashCode => Object.hash(id, email);
}

enum SignUpOutcome { signedIn, confirmEmail }

/// A safe, user-facing auth failure; provider messages are not shown raw.
class AuthFailure implements Exception {
  const AuthFailure(this.message);

  final String message;

  @override
  String toString() => 'AuthFailure($message)';
}

/// The only frontend boundary that talks to the Supabase SDK. Credentials,
/// refresh and verification stay with Supabase.
abstract interface class AuthRepository {
  AuthUser? get currentUser;

  /// Emits the current user (or null) first, then every change.
  Stream<AuthUser?> userChanges();

  /// Current access token; the SDK refreshes it before expiry.
  Future<String?> accessToken();

  Future<SignUpOutcome> signUp(String email, String password);

  Future<void> signIn(String email, String password);

  /// Clears local credentials even if the network revoke fails.
  Future<void> signOut();
}

/// Null in the UI-preview build, which has no identity at all.
final authRepositoryProvider = Provider<AuthRepository?>((ref) => null);

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._auth);

  final GoTrueClient _auth;

  static AuthUser? _toUser(User? u) =>
      u == null ? null : AuthUser(id: u.id, email: u.email ?? '');

  @override
  AuthUser? get currentUser => _toUser(_auth.currentUser);

  @override
  Stream<AuthUser?> userChanges() async* {
    yield currentUser;
    yield* _auth.onAuthStateChange.map((s) => _toUser(s.session?.user));
  }

  @override
  Future<String?> accessToken() async {
    final session = _auth.currentSession;
    if (session == null) return null;
    if (session.isExpired) {
      try {
        return (await _auth.refreshSession()).session?.accessToken;
      } on AuthException {
        return null; // the API then answers 401 and the app signs in again
      }
    }
    return session.accessToken;
  }

  @override
  Future<SignUpOutcome> signUp(String email, String password) async {
    try {
      final response = await _auth.signUp(email: email, password: password);
      return response.session == null
          ? SignUpOutcome.confirmEmail
          : SignUpOutcome.signedIn;
    } on AuthException catch (e) {
      throw _failure(e);
    }
  }

  @override
  Future<void> signIn(String email, String password) async {
    try {
      await _auth.signInWithPassword(email: email, password: password);
    } on AuthException catch (e) {
      throw _failure(e);
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _auth.signOut();
    } on AuthException {
      // The SDK already removed the local session before the revoke call;
      // a failed revoke must not keep the user signed in on this device.
    }
  }

  static AuthFailure _failure(AuthException e) {
    if (e is AuthRetryableFetchException) {
      return const AuthFailure(
        "Couldn't reach the sign-in service. Check your connection.",
      );
    }
    return AuthFailure(switch (e.code) {
      'invalid_credentials' => 'Email or password is incorrect.',
      'email_not_confirmed' =>
        'Confirm your email address first, then sign in.',
      'user_already_exists' || 'email_exists' =>
        'An account with this email already exists. Sign in instead.',
      'weak_password' => 'Choose a stronger password (at least 8 characters).',
      'over_email_send_rate_limit' || 'over_request_rate_limit' =>
        'Too many attempts. Wait a minute and try again.',
      _ => 'Sign-in failed. Try again.',
    });
  }
}
