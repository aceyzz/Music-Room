import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/models/auth/oauth_provider.dart';
import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/core/widgets/app_wordmark.dart';
import 'package:app/core/widgets/busy_state.dart';
import 'package:app/core/widgets/form_page.dart';
import 'package:app/core/widgets/loading_button.dart';
import 'package:app/core/widgets/or_divider.dart';
import 'package:app/features/auth/data/oauth_browser_flow.dart';
import 'package:app/features/auth/presentation/auth_error_messages.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/auth/presentation/widgets/oauth_buttons.dart';
import 'package:app/features/auth/presentation/widgets/server_dialog.dart';
import 'package:app/globals/app_router.dart';

/// Email + password sign-in, with links to sign-up and password reset.
///
/// No navigation on success: the router redirects on the new session state
/// (to /verify-email or the home page).
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with BusyState<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Which kind of request [busy] belongs to, so the spinner shows on the
  /// password button only when it is the password login that is running.
  bool _oauthInFlight = false;

  Future<void> _signInWith(OAuthProvider provider) async {
    final store = context.read<SessionStore>();
    _oauthInFlight = true;
    await run(
      () => store.signInWithProvider(provider),
      // Closing the login window is a choice, not an error.
      message: (error) =>
          error is OAuthCancelledError ? null : authErrorMessage(error, AuthAction.oauth),
    );
    _oauthInFlight = false;
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final store = context.read<SessionStore>();
    await run(
      () => store.login(email: _email.text, password: _password.text),
      message: (error) => authErrorMessage(error, AuthAction.login),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final store = context.read<SessionStore>();
    final expired = store.state.value == const SignedOut(expired: true);

    return FormPage(
      formKey: _formKey,
      children: [
        const AppWordmark(),
        if (expired) ...[
          FormGap.field,
          Text(
            'Your session has ended. Please sign in again.',
            style: TextStyle(color: colorScheme.error),
            textAlign: TextAlign.center,
          ),
        ],
        FormGap.large,
        EmailField(controller: _email),
        FormGap.field,
        PasswordField(controller: _password, onSubmitted: (_) => _submit()),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => context.go(forgotPasswordRoute),
            child: const Text('Forgot your password?'),
          ),
        ),
        FormGap.small,
        LoadingButton(
          label: 'Sign in',
          busy: busy && !_oauthInFlight,
          onPressed: busy ? null : _submit,
        ),
        FormGap.small,
        OutlinedButton(
          onPressed: busy ? null : () => context.go(registerRoute),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(AppDimens.buttonHeightStandard),
          ),
          child: const Text('Sign up'),
        ),
        FormGap.section,
        const OrDivider(),
        FormGap.section,
        OAuthButtons(
          available: store.oauthProviders,
          unavailableHint:
              store.oauthPlatformSupported ? '(not configured)' : '(not available here)',
          onPressed: busy ? null : _signInWith,
        ),
        FormGap.section,
        // Where the backend is: one APK, or one phone, reaches any machine.
        const Center(child: ServerButton()),
      ],
    );
  }
}
