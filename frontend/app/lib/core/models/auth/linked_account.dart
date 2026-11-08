import 'package:flutter/foundation.dart';

import 'package:app/core/models/auth/oauth_provider.dart';

/// A provider identity linked to the signed-in account (Profile, Linked
/// accounts). Linked either from that screen or by signing in with the
/// provider, which links it on the way.
@immutable
class LinkedAccount {
  final OAuthProvider provider;

  /// The address the provider reported; null if it gave none.
  final String? email;
  final DateTime linkedAt;

  const LinkedAccount({required this.provider, required this.linkedAt, this.email});

  @override
  bool operator ==(Object other) =>
      other is LinkedAccount &&
      other.provider == provider &&
      other.email == email &&
      other.linkedAt == linkedAt;

  @override
  int get hashCode => Object.hash(provider, email, linkedAt);
}

/// Every way into the account other than the email: the linked providers,
/// and whether a password is set too.
@immutable
class LinkedAccounts {
  final List<LinkedAccount> accounts;
  final bool hasPassword;

  const LinkedAccounts({required this.accounts, required this.hasPassword});

  LinkedAccount? of(OAuthProvider provider) {
    for (final account in accounts) {
      if (account.provider == provider) {
        return account;
      }
    }
    return null;
  }

  /// False when unlinking would leave no way to sign in: no password and
  /// this is the only provider. The server refuses that too
  /// (FailedPrecondition); this only lets the page say so before the tap.
  bool get canUnlink => hasPassword || accounts.length > 1;

  @override
  bool operator ==(Object other) =>
      other is LinkedAccounts &&
      other.hasPassword == hasPassword &&
      listEquals(other.accounts, accounts);

  @override
  int get hashCode => Object.hash(hasPassword, Object.hashAll(accounts));
}
