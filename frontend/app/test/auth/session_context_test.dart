import 'package:flutter/material.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:app/core/models/auth/auth_user.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';

import '../mocks/mock_flutter_secure_storage.dart';
import 'fake_auth_api.dart';

void main() {
  testWidgets('SessionContext provides currentUser and currentUserId', (tester) async {
    FlutterSecureStoragePlatform.instance = FakeFlutterSecureStoragePlatform();
    final credentials = SessionCredentials();
    final storage = TokenStorageService();
    final repo = SessionRepository(api: FakeAuthApi(), storage: storage, credentials: credentials);
    final store = SessionStore(repo, credentials);

    const user = AuthUser(
      publicId: 'user-123',
      email: 'test@example.com',
      displayName: 'Test User',
      emailVerified: true,
    );
    store.state.value = SignedIn(AuthSession(
      token: 'token',
      expiresAt: DateTime(2030),
      user: user,
    ));

    late AuthUser foundUser;
    late String foundUserId;

    await tester.pumpWidget(
      Provider<SessionStore>.value(
        value: store,
        child: Builder(
          builder: (context) {
            foundUser = context.currentUser;
            foundUserId = context.currentUserId;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(foundUser, equals(user));
    expect(foundUserId, equals('user-123'));
    expect(store.currentUser, equals(user));
  });
}
