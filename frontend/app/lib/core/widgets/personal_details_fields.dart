import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:app/core/validation/validators.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/core/widgets/form_page.dart';

/// The standard personal details form fields shared by the registration
/// and profile editing pages.
class PersonalDetailsFields extends StatelessWidget {
  final TextEditingController firstName;
  final TextEditingController lastName;
  final ValueNotifier<DateTime?> birthDate;
  final TextEditingController city;
  final TextEditingController country;
  final TextEditingController phone;
  final TextEditingController bio;
  final bool enabled;

  const PersonalDetailsFields({
    super.key,
    required this.firstName,
    required this.lastName,
    required this.birthDate,
    required this.city,
    required this.country,
    required this.phone,
    required this.bio,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: AppTextField(
                controller: firstName,
                label: 'First name',
                enabled: enabled,
                textCapitalization: TextCapitalization.words,
                autofillHints: const [AutofillHints.givenName],
              ),
            ),
            FormGap.inline,
            Expanded(
              child: AppTextField(
                controller: lastName,
                label: 'Last name',
                enabled: enabled,
                textCapitalization: TextCapitalization.words,
                autofillHints: const [AutofillHints.familyName],
              ),
            ),
          ],
        ),
        FormGap.field,
        DateField(value: birthDate, label: 'Birth date'),
        FormGap.field,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: AppTextField(
                controller: city,
                label: 'City',
                icon: Icons.location_city_outlined,
                enabled: enabled,
                textCapitalization: TextCapitalization.words,
                autofillHints: const [AutofillHints.addressCity],
              ),
            ),
            FormGap.inline,
            Expanded(
              child: AppTextField(
                controller: country,
                label: 'Country',
                hint: 'FR',
                maxLength: 2,
                enabled: enabled,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp('[a-zA-Z]')),
                  UpperCaseFormatter(),
                ],
                validator: Validators.optional(Validators.countryCode('2 letters')),
              ),
            ),
          ],
        ),
        FormGap.field,
        AppTextField(
          controller: phone,
          label: 'Phone',
          icon: Icons.phone_outlined,
          enabled: enabled,
          keyboardType: TextInputType.phone,
          autofillHints: const [AutofillHints.telephoneNumber],
          validator: Validators.optional(Validators.phone()),
        ),
        FormGap.field,
        AppTextField(
          controller: bio,
          label: 'Bio',
          hint: 'A few words about you and your music',
          enabled: enabled,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          maxLines: 3,
        ),
      ],
    );
  }
}
