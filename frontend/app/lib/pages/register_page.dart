import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/models/user/profile_update.dart';
import 'package:app/core/validation/validators.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/core/widgets/app_wordmark.dart';
import 'package:app/core/widgets/busy_state.dart';
import 'package:app/core/widgets/form_page.dart';
import 'package:app/core/widgets/loading_button.dart';
import 'package:app/core/widgets/personal_details_fields.dart';
import 'package:app/features/auth/presentation/auth_error_messages.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/globals/app_router.dart';

/// Sign-up. Email, display name and password are what Register requires;
/// the rest is the optional profile (user_profiles), saved right after.
///
/// No navigation on success: the router moves a new, unverified account to
/// /verify-email by itself.
class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> with BusyState<RegisterPage> {
  final _formKey = GlobalKey<FormState>();

  final _email = TextEditingController();
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _birthDate = ValueNotifier<DateTime?>(null);
  final _city = TextEditingController();
  final _country = TextEditingController();
  final _phone = TextEditingController();
  final _bio = TextEditingController();

  @override
  void dispose() {
    for (final c in [
      _email, _displayName, _password, _confirm,
      _firstName, _lastName, _city, _country, _phone, _bio,
    ]) {
      c.dispose();
    }
    _birthDate.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final store = context.read<SessionStore>();
    // Captured now: by the time register returns, the router has replaced
    // this page, but the app-wide messenger is still there.
    final messenger = ScaffoldMessenger.of(context);
    final profile = ProfileUpdate.fromForm(
      firstName: _firstName.text,
      lastName: _lastName.text,
      birthDate: _birthDate.value,
      city: _city.text,
      countryCode: _country.text,
      phoneNumber: _phone.text,
      bio: _bio.text,
    );
    await run(
      () async {
        final profileSaved = await store.register(
          email: _email.text,
          password: _password.text,
          displayName: _displayName.text,
          profile: profile,
        );
        if (!profileSaved) {
          messenger.showSnackBar(const SnackBar(
            content: Text('Account created, but your profile details could not be saved. '
                'You can add them later.'),
          ));
        }
      },
      message: (error) => authErrorMessage(error, AuthAction.register),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return FormPage(
      formKey: _formKey,
      children: [
        const AppWordmark(subtitle: 'Create your account'),
        FormGap.large,
        EmailField(controller: _email),
        FormGap.field,
        AppTextField(
          controller: _displayName,
          label: 'Display name',
          hint: 'How others see you',
          icon: Icons.alternate_email_rounded,
          autofillHints: const [AutofillHints.nickname],
          validator: Validators.required('Choose a display name'),
        ),
        FormGap.field,
        PasswordField(
          controller: _password,
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
          label: 'Confirm password',
          isNew: true,
          textInputAction: TextInputAction.next,
          validator: Validators.matches(_password, 'Passwords do not match'),
        ),
        FormGap.section,
        Text('Optional', style: textTheme.titleSmall),
        FormGap.small,
        PersonalDetailsFields(
          firstName: _firstName,
          lastName: _lastName,
          birthDate: _birthDate,
          city: _city,
          country: _country,
          phone: _phone,
          bio: _bio,
        ),
        FormGap.large,
        LoadingButton(label: 'Create account', busy: busy, onPressed: _submit),
        FormGap.small,
        TextButton(
          onPressed: busy ? null : () => context.go(loginRoute),
          child: const Text('Already have an account? Sign in'),
        ),
      ],
    );
  }
}
