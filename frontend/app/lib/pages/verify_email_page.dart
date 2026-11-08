import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:app/core/validation/validators.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/core/widgets/app_wordmark.dart';
import 'package:app/core/widgets/busy_state.dart';
import 'package:app/core/widgets/form_page.dart';
import 'package:app/core/widgets/loading_button.dart';
import 'package:app/features/auth/presentation/auth_error_messages.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';

/// Asks for the 6-digit code emailed at sign-up (subject V.1: "the
/// application must demand a mail validation").
///
/// The router keeps an unverified user on this page. Once the code is
/// accepted the session is marked verified and the router moves on by itself.
class VerifyEmailPage extends StatefulWidget {
  const VerifyEmailPage({super.key});

  @override
  State<VerifyEmailPage> createState() => _VerifyEmailPageState();
}

class _VerifyEmailPageState extends State<VerifyEmailPage> with BusyState<VerifyEmailPage> {
  final _formKey = GlobalKey<FormState>();
  final _code = TextEditingController();

  /// Which action [busy] belongs to, so the spinner shows on the right button.
  bool _resending = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final store = context.read<SessionStore>();
    await run(
      () => store.verifyEmail(_code.text),
      message: (error) => authErrorMessage(error, AuthAction.verifyEmail),
    );
  }

  Future<void> _resend() async {
    final store = context.read<SessionStore>();
    _resending = true;
    final sent = await run(
      store.resendVerificationCode,
      message: (error) => authErrorMessage(error, AuthAction.resendCode),
    );
    _resending = false;
    if (sent) {
      showInfo('A new code is on its way.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = context.read<SessionStore>();
    final email = switch (store.state.value) {
      SignedIn(:final user) => user.email,
      SignedOut() => '',
    };

    return FormPage(
      formKey: _formKey,
      children: [
        AppWordmark(
          icon: Icon(Icons.mark_email_read_outlined, size: 64, color: theme.colorScheme.primary),
          title: 'Verify your email',
          subtitle: email.isEmpty
              ? 'Enter the 6-digit code we emailed you.'
              : 'Enter the 6-digit code we sent to $email.',
          iconSpacing: 24,
        ),
        FormGap.large,
        AppTextField(
          controller: _code,
          label: 'Code',
          icon: Icons.pin_outlined,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          maxLength: 6,
          autofillHints: const [AutofillHints.oneTimeCode],
          onSubmitted: (_) => _verify(),
          validator: Validators.digits(6, 'The code is 6 digits'),
        ),
        FormGap.section,
        LoadingButton(
          label: 'Verify',
          busy: busy && !_resending,
          onPressed: busy ? null : _verify,
        ),
        FormGap.small,
        TextButton(
          onPressed: busy ? null : _resend,
          child: const Text('Send a new code'),
        ),
        TextButton(
          // The router sends the user back to /login.
          onPressed: busy ? null : store.logout,
          child: const Text('Use another account'),
        ),
      ],
    );
  }
}
