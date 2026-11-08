import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/widgets/user_avatar.dart';
import 'package:app/core/widgets/user_tile.dart';

void main() {
  testWidgets('renders simple user tile with subtitle and trailing', (tester) async {
    var tapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserTile(
            name: 'Alice Wonder',
            subtitle: 'Online',
            trailing: const Icon(Icons.chevron_right),
            onTap: () => tapped = true,
          ),
        ),
      ),
    );

    expect(find.text('Alice Wonder'), findsOneWidget);
    expect(find.text('Online'), findsOneWidget);
    expect(find.byType(UserAvatar), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    await tester.tap(find.text('Alice Wonder'));
    expect(tapped, isTrue);
  });

  testWidgets('renders user tile with actions row', (tester) async {
    var tapped = false;
    var accepted = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserTile(
            name: 'Bob Builder',
            subtitle: 'Wants to be friends',
            onTap: () => tapped = true,
            actions: ElevatedButton(
              onPressed: () => accepted = true,
              child: const Text('Accept'),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Bob Builder'), findsOneWidget);
    expect(find.text('Wants to be friends'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
    expect(find.byType(UserAvatar), findsOneWidget);

    await tester.tap(find.text('Accept'));
    expect(accepted, isTrue);
    expect(tapped, isFalse);

    await tester.tap(find.text('Bob Builder'));
    expect(tapped, isTrue);
  });
}
