import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/primary_action.dart';
import '../../today/presentation/today_widgets.dart';
import '../application/auth_controller.dart';
import '../data/auth_repository.dart';

/// Shared frame: wordmark, heading, short note, then the form or actions.
class _AuthScaffold extends StatelessWidget {
  const _AuthScaffold({
    required this.title,
    required this.note,
    required this.children,
  });

  final String title;
  final String note;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          children: [
            const Wordmark(),
            const SizedBox(height: 40),
            Semantics(
              header: true,
              child: Text(title, style: text.headlineMedium),
            ),
            const SizedBox(height: 8),
            Text(
              note,
              style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: 28),
            ...children,
          ],
        ),
      ),
    );
  }
}

InputDecoration _field(BuildContext context, String label) => InputDecoration(
  labelText: label,
  filled: true,
  fillColor: AppColors.surface,
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppRadii.chip),
    borderSide: BorderSide.none,
  ),
);

/// Email/password form used by sign-in and sign-up.
class _CredentialsForm extends ConsumerStatefulWidget {
  const _CredentialsForm({required this.submitLabel, required this.onSubmit});

  final String submitLabel;
  final Future<void> Function(String email, String password) onSubmit;

  @override
  ConsumerState<_CredentialsForm> createState() => _CredentialsFormState();
}

class _CredentialsFormState extends ConsumerState<_CredentialsForm> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (!email.contains('@') || password.length < 8) {
      setState(
        () => _error =
            'Enter your email and a password of at least 8 characters.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(email, password);
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            textInputAction: TextInputAction.next,
            decoration: _field(context, 'Email'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => _submit(),
            decoration: _field(context, 'Password'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: AppColors.accent),
            ),
          ],
          const SizedBox(height: 24),
          PrimaryAction(
            label: widget.submitLabel,
            loading: _busy,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}

class SignInPage extends ConsumerWidget {
  const SignInPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => _AuthScaffold(
    title: 'Sign in',
    note: 'One movie from your own watchlist, every night.',
    children: [
      _CredentialsForm(
        submitLabel: 'Sign in',
        onSubmit: (email, password) =>
            ref.read(authRepositoryProvider)!.signIn(email, password),
      ),
      const SizedBox(height: 8),
      Center(
        child: TextButton(
          onPressed: () => context.go('/sign-up'),
          child: const Text('Create an account'),
        ),
      ),
    ],
  );
}

class SignUpPage extends ConsumerWidget {
  const SignUpPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => _AuthScaffold(
    title: 'Create your account',
    note: "We'll email you a link to confirm your address.",
    children: [
      _CredentialsForm(
        submitLabel: 'Create account',
        onSubmit: (email, password) async {
          final outcome = await ref
              .read(authRepositoryProvider)!
              .signUp(email, password);
          if (outcome == SignUpOutcome.confirmEmail && context.mounted) {
            context.go(
              Uri(
                path: '/check-email',
                queryParameters: {'email': email},
              ).toString(),
            );
          }
        },
      ),
      const SizedBox(height: 8),
      Center(
        child: TextButton(
          onPressed: () => context.go('/sign-in'),
          child: const Text('I already have an account'),
        ),
      ),
    ],
  );
}

/// After sign-up without a session, or when the API reports an unconfirmed
/// email. The link is opened outside the app; then the user signs in.
class CheckEmailPage extends ConsumerWidget {
  const CheckEmailPage({super.key, this.email});

  final String? email;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signedIn = ref.watch(currentUserIdProvider) != null;
    final to = email == null || email!.isEmpty ? 'your email' : email!;
    return _AuthScaffold(
      title: 'Check your email',
      note:
          'We sent a confirmation link to $to. Open it, then come back and sign in.',
      children: [
        if (signedIn) ...[
          PrimaryAction(
            label: "I've confirmed it",
            onPressed: () => ref.invalidate(accountProvider),
          ),
          Center(
            child: TextButton(
              onPressed: () => ref.read(authRepositoryProvider)!.signOut(),
              child: const Text('Sign out'),
            ),
          ),
        ] else
          PrimaryAction(
            label: 'Back to sign in',
            onPressed: () => context.go('/sign-in'),
          ),
      ],
    );
  }
}

/// Checking the stored session, or setting up the profile. A failure shows
/// Retry and keeps the signed-in session (no logout on infrastructure errors).
class StartingPage extends ConsumerWidget {
  const StartingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final error = account.error;
    final text = Theme.of(context).textTheme;
    if (error == null || account.isLoading) {
      return Scaffold(
        body: Center(
          child: Semantics(
            label: 'Setting up Cinemé',
            child: const CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }
    final message = error is ApiError
        ? error.message
        : "Couldn't set up your account. Try again.";
    return _AuthScaffold(
      title: "Couldn't finish signing in",
      note: message,
      children: [
        PrimaryAction(
          label: 'Retry',
          onPressed: () => ref.invalidate(accountProvider),
        ),
        Center(
          child: TextButton(
            onPressed: () => ref.read(authRepositoryProvider)!.signOut(),
            child: Text('Sign out', style: text.labelLarge),
          ),
        ),
      ],
    );
  }
}

/// A normal build without configuration never falls back to fake data.
class ConfigMissingPage extends ConsumerWidget {
  const ConfigMissingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final missing = ref.watch(appConfigProvider).missing;
    return _AuthScaffold(
      title: 'This build is not configured',
      note:
          'Build with --dart-define-from-file (see docs/TOOLING.md). Missing: ${missing.join(', ')}.',
      children: const [],
    );
  }
}
