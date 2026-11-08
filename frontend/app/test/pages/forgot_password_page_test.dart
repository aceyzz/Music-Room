import 'package:flutter/material.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/pages/forgot_password_page.dart';

import '../auth/fake_auth_api.dart';
import '../mocks/mock_flutter_secure_storage.dart';

void main() {
  late FakeAuthApi api;
  late SessionStore session;

  setUp(() async {
    FlutterSecureStoragePlatform.instance = FakeFlutterSecureStoragePlatform();
    api = FakeAuthApi();
    final credentials = SessionCredentials();
    session = SessionStore(
      SessionRepository(
        api: api,
        storage: TokenStorageService(),
        credentials: credentials,
      ),
      credentials,
    );
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<SessionStore>.value(value: session),
        ],
        child: MaterialApp(
          theme: AppTheme.lightTheme(),
          home: const ForgotPasswordPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders initial email step and validates empty input', (tester) async {
    await pumpPage(tester);

    expect(find.text('Send code'), findsOneWidget);
    expect(find.text('Back to sign in'), findsOneWidget);

    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();

    expect(find.text('Enter your email'), findsOneWidget);
  });

  testWidgets('sends code and transitions to step 2', (tester) async {
    await pumpPage(tester);

    await tester.enterText(find.byType(TextFormField).first, 'test@example.com');
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();

    expect(find.text('Reset password'), findsOneWidget);
    expect(find.text('Send a new code'), findsOneWidget);
    expect(find.text('Code'), findsOneWidget);
    expect(find.text('New password'), findsOneWidget);
    expect(find.text('Confirm new password'), findsOneWidget);
  });
}
