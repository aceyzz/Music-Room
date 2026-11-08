import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/auth/linked_account.dart';
import 'package:app/core/models/auth/oauth_provider.dart';
import 'package:app/features/auth/data/auth_source.dart';

/// In-memory [LinkedAccountsApi] that keeps the server's rules: one identity
/// per provider, and no unlinking the last way to sign in.
class FakeLinkedAccountsApi implements LinkedAccountsApi {
  final List<String> calls = [];
  final Map<String, AppError> failures = {};

  final Map<OAuthProvider, LinkedAccount> linked = {};
  bool hasPassword = true;

  /// The arguments of the last [linkOAuthAccount] call.
  ({OAuthProvider provider, String code, String redirectUri})? lastLink;

  void _call(String name) {
    calls.add(name);
    final failure = failures[name];
    if (failure != null) {
      throw failure;
    }
  }

  @override
  Future<LinkedAccounts> listOAuthAccounts() async {
    _call('listOAuthAccounts');
    return LinkedAccounts(accounts: linked.values.toList(), hasPassword: hasPassword);
  }

  @override
  Future<void> linkOAuthAccount({
    required OAuthProvider provider,
    required String code,
    required String redirectUri,
  }) async {
    _call('linkOAuthAccount');
    lastLink = (provider: provider, code: code, redirectUri: redirectUri);
    if (linked.containsKey(provider)) {
      throw const ConflictError('account already linked to this provider');
    }
    linked[provider] = LinkedAccount(
      provider: provider,
      email: '${provider.wireName}@example.test',
      linkedAt: DateTime.utc(2026, 10, 17),
    );
  }

  @override
  Future<void> unlinkOAuthAccount(OAuthProvider provider) async {
    _call('unlinkOAuthAccount');
    if (!linked.containsKey(provider)) {
      throw const NotFoundError('provider not linked to this account');
    }
    if (!hasPassword && linked.length <= 1) {
      throw const PreconditionFailedError('cannot remove the last login method');
    }
    linked.remove(provider);
  }
}
