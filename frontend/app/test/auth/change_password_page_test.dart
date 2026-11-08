import 'package:flutter/material.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/globals/app_router.dart';
import 'package:app/pages/forgot_password_page.dart';

import '../mocks/mock_flutter_secure_storage.dart';
import 'fake_auth_api.dart';

// The reset page as the profile's Change password, under a small router: the
// profile only says where it is.
void main() {
  late FakeAuthApi api;
  late SessionStore session;

  setUp(() async {
    FlutterSecureStoragePlatform.instance = FakeFlutterSecureStoragePlatform();
    api = FakeAuthApi()..emailVerified = true;
    final credentials = SessionCredentials();
    session = SessionStore(
      SessionRepository(
        api: api,
        storage: TokenStorageService(),
        credentials: credentials,
        devSessionToken: '',
      ),
      credentials,
    );
    await session.start();
    await session.login(email: 'neo@example.test', password: 'password1234');
    api.calls.clear();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    final router = GoRouter(initialLocation: profileRoute, routes: [
      GoRoute(
        path: profileRoute,
        builder: (context, state) => const Scaffold(body: Text('the profile')),
      ),
      GoRoute(
        path: changePasswordRoute,
        builder: (context, state) => const ForgotPasswordPage(email: 'neo@example.test'),
      ),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<SessionStore>.value(value: session)],
      child: MaterialApp.router(routerConfig: router),
    ));
    router.push(changePasswordRoute);
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);

  testWidgets('the code goes to the account\'s own address, never asked', (tester) async {
    await pumpPage(tester);

    expect(find.text('Change password'), findsOneWidget);
    expect(find.textContaining('neo@example.test'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);

    await tap(tester, 'Send code');
    expect(api.calls, ['requestPasswordReset']);
    expect(field('Code'), findsOneWidget);
    expect(field('New password'), findsOneWidget);
  });

  testWidgets('the new password signs back in and returns to the profile', (tester) async {
    await pumpPage(tester);
    await tap(tester, 'Send code');

    await tester.enterText(field('Code'), '123456');
    await tester.enterText(field('New password'), 'new-password');
    await tester.enterText(field('Confirm new password'), 'new-password');
    await tap(tester, 'Reset password');

    expect(api.calls, ['requestPasswordReset', 'resetPassword', 'login']);
    expect(
      api.lastReset,
      (email: 'neo@example.test', code: '123456', newPassword: 'new-password'),
    );
    expect(session.state.value, isA<SignedIn>());
    expect(find.text('the profile'), findsOneWidget);
    expect(find.text('Password changed.'), findsOneWidget);
  });

  testWidgets('Cancel goes back without a call', (tester) async {
    await pumpPage(tester);

    await tap(tester, 'Cancel');
    expect(find.text('the profile'), findsOneWidget);
    expect(api.calls, isEmpty);
  });
}
