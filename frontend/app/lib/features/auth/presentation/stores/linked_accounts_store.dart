import 'package:flutter/foundation.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/auth/linked_account.dart';
import 'package:app/core/models/auth/oauth_provider.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/features/auth/data/auth_source.dart';
import 'package:app/features/auth/data/oauth_browser_flow.dart';

/// The Linked accounts section of the profile page: which providers sign
/// into this account, and linking or unlinking one (subject: "link their
/// network account (Facebook or Google)").
///
/// Page-level, like ProfileStore (see globals/app_router.dart): reopening the
/// page refetches. [start] reports failure through [state]; [link] and
/// [unlink] throw [AppError] and leave [state] as it was, so the page shows
/// the error where the user tapped.
class LinkedAccountsStore {
  final LinkedAccountsApi _api;

  /// The same login window as "Sign in with ...": linking is that flow with
  /// a different RPC at the end, so it reuses the redirect URI the providers
  /// already accept.
  final OAuthBrowserFlow _oauth;

  final ValueNotifier<ItemState<LinkedAccounts>> state = ValueNotifier(ItemState.initial());

  /// Set by [stop]: a link can outlive the page (back pressed while the
  /// login window is open), and writing to a disposed notifier throws.
  bool _stopped = false;

  LinkedAccountsStore(this._api, this._oauth);

  LinkedAccounts? get accounts => state.value.data;

  /// Providers this build can open a login window for. A provider outside
  /// this set can still show as linked (signed in from another build), but
  /// cannot be linked from here.
  Set<OAuthProvider> get linkableProviders => _oauth.config.availableProviders;

  Future<void> start() => reload();

  void stop() {
    _stopped = true;
    state.dispose();
  }

  void _set(ItemState<LinkedAccounts> next) {
    if (!_stopped) {
      state.value = next;
    }
  }

  Future<void> reload() async {
    _set(ItemState.loading(accounts));
    try {
      _set(ItemState.success(await _api.listOAuthAccounts()));
    } on AppError catch (error) {
      _set(ItemState.error(error, accounts));
    }
  }

  /// Opens the provider's login window, then links what comes back. Throws
  /// [OAuthCancelledError] if the user backs out, which is not an error to
  /// report.
  ///
  /// Refetches rather than inserting the row itself: the server knows the
  /// email the provider reported and the link time, and the list is tiny.
  Future<void> link(OAuthProvider provider) async {
    final authorization = await _oauth.authorize(provider);
    await _api.linkOAuthAccount(
      provider: provider,
      code: authorization.code,
      redirectUri: authorization.redirectUri,
    );
    await reload();
  }

  Future<void> unlink(OAuthProvider provider) async {
    await _api.unlinkOAuthAccount(provider);
    await reload();
  }
}
