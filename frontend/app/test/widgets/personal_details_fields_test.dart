import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/widgets/personal_details_fields.dart';

void main() {
  testWidgets('PersonalDetailsFields renders all personal inputs and binds controllers',
      (tester) async {
    final firstName = TextEditingController();
    final lastName = TextEditingController();
    final birthDate = ValueNotifier<DateTime?>(null);
    final city = TextEditingController();
    final country = TextEditingController();
    final phone = TextEditingController();
    final bio = TextEditingController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PersonalDetailsFields(
              firstName: firstName,
              lastName: lastName,
              birthDate: birthDate,
              city: city,
              country: country,
              phone: phone,
              bio: bio,
            ),
          ),
        ),
      ),
    );

    expect(find.widgetWithText(TextFormField, 'First name'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Last name'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Birth date'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'City'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Country'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Phone'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Bio'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'First name'), 'Thomas');
    expect(firstName.text, 'Thomas');

    await tester.enterText(find.widgetWithText(TextFormField, 'Country'), 'fr');
    expect(country.text, 'FR'); // UpperCaseFormatter
  });
}
