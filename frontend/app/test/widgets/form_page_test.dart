import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/widgets/form_page.dart';

void main() {
  group('FormPage', () {
    testWidgets('renders children in a scrollable centered column', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: FormPage(
            children: [
              Text('Field 1'),
              FormGap.field,
              Text('Field 2'),
            ],
          ),
        ),
      );

      expect(find.text('Field 1'), findsOneWidget);
      expect(find.text('Field 2'), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });

    testWidgets('wraps content in Form when formKey is provided', (tester) async {
      final formKey = GlobalKey<FormState>();
      await tester.pumpWidget(
        MaterialApp(
          home: FormPage(
            formKey: formKey,
            children: const [
              Text('Inside Form'),
            ],
          ),
        ),
      );

      expect(find.byType(Form), findsOneWidget);
      expect(find.text('Inside Form'), findsOneWidget);
    });

    testWidgets('renders appBar when provided', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: FormPage(
            appBar: AppBar(title: const Text('Title')),
            children: const [
              Text('Body'),
            ],
          ),
        ),
      );

      expect(find.text('Title'), findsOneWidget);
      expect(find.text('Body'), findsOneWidget);
    });
  });
}
