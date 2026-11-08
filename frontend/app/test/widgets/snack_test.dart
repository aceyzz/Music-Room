import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/widgets/snack.dart';

void main() {
  /// A page whose button calls [onTap] with its context.
  Future<void> pumpButton(WidgetTester tester, void Function(BuildContext) onTap) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(onPressed: () => onTap(context), child: const Text('Go')),
          ),
        ),
      ));

  testWidgets('the same message four times shows once', (tester) async {
    await pumpButton(tester, (context) => showSnack(context, 'Not at the venue', error: true));

    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('Go'));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('Not at the venue'), findsOneWidget);

    // Gone after its 4 s: nothing was queued behind it.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Not at the venue'), findsNothing);
  });

  testWidgets('once it has gone, the same message shows again', (tester) async {
    await pumpButton(tester, (context) => showSnack(context, 'Not at the venue'));

    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Not at the venue'), findsNothing);

    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(find.text('Not at the venue'), findsOneWidget);
  });

  testWidgets('a different message still waits its turn', (tester) async {
    var n = 0;
    await pumpButton(tester, (context) => showSnack(context, ++n == 1 ? 'First' : 'Second'));

    await tester.tap(find.text('Go'));
    await tester.pump();
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsNothing);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsOneWidget);
  });

  testWidgets('replace: a different message takes the place of the one showing', (tester) async {
    var n = 0;
    await pumpButton(tester, (context) => showSnack(context, ++n == 1 ? 'First' : 'Second', replace: true));

    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
  });
}
