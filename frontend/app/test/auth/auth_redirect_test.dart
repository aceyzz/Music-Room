import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/models/auth/auth_user.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/globals/app_router.dart';

SignedIn signedIn({required bool verified}) => SignedIn(AuthSession(
      token: 't',
      expiresAt: DateTime(2100),
      user: AuthUser(publicId: 'u', displayName: 'neo', email: 'e', emailVerified: verified),
    ));

void main() {
  group('authRedirect', () {
    test('signed out: everything leads to the login page', () {
      expect(authRedirect(const SignedOut(), homeRoute), loginRoute);
      expect(authRedirect(const SignedOut(), profileRoute), loginRoute);
      expect(authRedirect(const SignedOut(), verifyEmailRoute), loginRoute);
      expect(authRedirect(const SignedOut(), changePasswordRoute), loginRoute);
      expect(authRedirect(const SignedOut(), loginRoute), isNull);
    });

    test('signed out: sign-up and password reset stay reachable', () {
      expect(authRedirect(const SignedOut(), registerRoute), isNull);
      expect(authRedirect(const SignedOut(), forgotPasswordRoute), isNull);
    });

    test('signed in but unverified: held on the verification page', () {
      final session = signedIn(verified: false);
      expect(authRedirect(session, homeRoute), verifyEmailRoute);
      expect(authRedirect(session, loginRoute), verifyEmailRoute);
      expect(authRedirect(session, verifyEmailRoute), isNull);
      expect(authRedirect(session, registerRoute), verifyEmailRoute);
    });

    test('signed in and verified: free to roam, but not back to the auth pages', () {
      final session = signedIn(verified: true);
      expect(authRedirect(session, homeRoute), isNull);
      expect(authRedirect(session, profileRoute), isNull);
      expect(authRedirect(session, changePasswordRoute), isNull);
      expect(authRedirect(session, loginRoute), homeRoute);
      expect(authRedirect(session, verifyEmailRoute), homeRoute);
      expect(authRedirect(session, registerRoute), homeRoute);
      expect(authRedirect(session, forgotPasswordRoute), homeRoute);
    });
  });
}
