import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/validation/validators.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/core/widgets/app_wordmark.dart';
import 'package:app/core/widgets/busy_state.dart';
import 'package:app/core/widgets/form_page.dart';
import 'package:app/core/widgets/loading_button.dart';
import 'package:app/features/auth/presentation/auth_error_messages.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/globals/app_router.dart';

/// Password reset in two steps on one page: ask for a code by email, then
/// enter it with a new password. Success signs in, and the router moves on.
///
/// The first step always "succeeds": the server answers the same whether or
/// not the address has an account, so the page can't tell and doesn't try.
///
/// With [email], the same page changes the password of the signed-in user
/// (Profile, Change password). AuthService has no ChangePassword RPC, and the
/// reset flow needs none: proving the inbox is enough, and it also gives an
/// OAuth-only account, which has no current password to type, a first one.
/// ResetPassword revokes every session, so the other devices are signed out;
/// this one signs straight back in. A call that leaves with the old token in
/// between and comes back rejected signs the user out: rare, and harmless,
/// the new password is known.
class ForgotPasswordPage extends StatefulWidget {
  /// The signed-in user's address; null on the signed-out reset page.
  final String? email;

  const ForgotPasswordPage({super.key, this.email});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage>
    with BusyState<ForgotPasswordPage> {
  // ---------------------------------------------------------------------------
  // State Variables & Controllers
  // ---------------------------------------------------------------------------

  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  /// True once the email has been submitted and the reset code is requested.
  bool _codeSent = false;

  bool get _changing => widget.email != null;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _email.text = widget.email ?? '';
  }

  @override
  void dispose() {
    for (final c in [_email, _code, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  /// Requests a password reset code sent to the specified email address.
  Future<void> _sendCode() async {
    // On a resend the form holds the (still empty) code fields instead; the
    // email was validated the first time.
    if (!_codeSent && !(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final store = context.read<SessionStore>();
    final sent = await run(
      () => store.requestPasswordReset(_email.text),
      message: (error) => authErrorMessage(error, AuthAction.requestReset),
    );
    if (!sent || !mounted) {
      return;
    }
    if (_codeSent) {
      showInfo('A new code is on its way.');
    } else {
      setState(() => _codeSent = true);
    }
  }

  /// Validates and submits the new password with the emailed reset code.
  Future<void> _reset() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final store = context.read<SessionStore>();
    final changed = await run(
      () => store.resetPassword(
        email: _email.text,
        code: _code.text,
        newPassword: _password.text,
      ),
      message: (error) => authErrorMessage(error, AuthAction.resetPassword),
    );
    // Signed out, the router moves on by itself once signed in. Changing,
    // the user was signed in all along: nothing moves unless the page does.
    if (changed && _changing && mounted) {
      showInfo('Password changed.');
      context.pop();
    }
  }

  // ---------------------------------------------------------------------------
  // Computed Views (Subviews)
  // ---------------------------------------------------------------------------

  /// Header wordmark and dynamic instruction subtitle.
  Widget get _header {
    final email = _email.text.trim();
    return AppWordmark(
      subtitle: switch ((_changing, _codeSent)) {
        (true, false) => 'We will send a code to $email to set your new password.',
        (true, true) => 'A 6-digit code is on its way to $email.',
        (false, true) => 'If $email has an account, a 6-digit code is on its way.',
        (false, false) => 'Enter your email and we will send you a code to reset your password.',
      },
    );
  }

  /// Initial email input field shown in step 1.
  Widget get _emailField => EmailField(
        controller: _email,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _sendCode(),
      );

  /// Reset verification code and new password fields shown in step 2.
  List<Widget> get _resetFields => [
        AppTextField(
          controller: _code,
          label: 'Code',
          icon: Icons.pin_outlined,
          keyboardType: TextInputType.number,
          maxLength: 6,
          autofillHints: const [AutofillHints.oneTimeCode],
          validator: Validators.digits(6, 'The code is 6 digits'),
        ),
        FormGap.field,
        PasswordField(
          controller: _password,
          label: 'New password',
          isNew: true,
          textInputAction: TextInputAction.next,
          validator: Validators.compose([
            Validators.required('Choose a password'),
            Validators.minLength(8, 'At least 8 characters'),
          ]),
        ),
        FormGap.field,
        PasswordField(
          controller: _confirm,
          label: 'Confirm new password',
          isNew: true,
          onSubmitted: (_) => _reset(),
          validator: Validators.matches(_password, 'Passwords do not match'),
        ),
      ];

  /// Primary submit button for either requesting a code or resetting password.
  Widget get _submitButton => LoadingButton(
        label: _codeSent ? 'Reset password' : 'Send code',
        busy: busy,
        onPressed: _codeSent ? _reset : _sendCode,
      );

  /// Secondary action to resend the 6-digit reset code.
  Widget get _resendCodeButton => TextButton(
        onPressed: busy ? null : _sendCode,
        child: const Text('Send a new code'),
      );

  /// Navigation link back to the login screen.
  Widget get _backToSignInButton => TextButton(
        onPressed: busy ? null : () => _changing ? context.pop() : context.go(loginRoute),
        child: Text(_changing ? 'Cancel' : 'Back to sign in'),
      );

  // ---------------------------------------------------------------------------
  // Main Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return FormPage(
      formKey: _formKey,
      appBar: _changing ? AppBar(title: const Text('Change password'), centerTitle: true) : null,
      children: [
        _header,
        FormGap.large,
        // Locked once the code is sent: the code is only valid for this address.
        // Changing, it is the account's own and never asked.
        if (!_codeSent && !_changing)
          _emailField
        else if (_codeSent)
          ..._resetFields,
        FormGap.section,
        _submitButton,
        if (_codeSent) _resendCodeButton,
        _backToSignInButton,
      ],
    );
  }
}
