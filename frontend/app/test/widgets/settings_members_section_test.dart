import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/widgets/inline_loader.dart';
import 'package:app/core/widgets/settings_members_section.dart';

typedef _TestMember = ({String publicId, String displayName, String? avatarUrl, String role});

void main() {
  testWidgets('SettingsMembersSection renders loading when members is null', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsMembersSection<_TestMember>(
            members: null,
            hasError: false,
            currentUserId: 'u-1',
            canInvite: true,
            onInvite: () {},
            displayName: (m) => m.displayName,
            avatarUrl: (m) => m.avatarUrl,
            publicId: (m) => m.publicId,
            roleLabel: (m) => m.role,
          ),
        ),
      ),
    );

    expect(find.text('Invited people'), findsOneWidget);
    expect(find.byType(InlineLoader), findsOneWidget);
    expect(find.text('Invite'), findsOneWidget);
  });

  testWidgets('SettingsMembersSection renders members with (you) suffix and badges',
      (tester) async {
    final members = <_TestMember>[
      (publicId: 'u-1', displayName: 'Alex', avatarUrl: null, role: 'Owner'),
      (publicId: 'u-2', displayName: 'Sam', avatarUrl: null, role: 'Invited'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsMembersSection<_TestMember>(
            members: members,
            hasError: false,
            currentUserId: 'u-1',
            canInvite: false,
            onInvite: null,
            displayName: (m) => m.displayName,
            avatarUrl: (m) => m.avatarUrl,
            publicId: (m) => m.publicId,
            roleLabel: (m) => m.role,
          ),
        ),
      ),
    );

    expect(find.text('Alex (you)'), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('Owner'), findsOneWidget);
    expect(find.text('Invited'), findsOneWidget);
    expect(find.text('Invite'), findsNothing);
  });
}
