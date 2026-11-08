import 'package:flutter/material.dart';

import 'package:app/core/models/auth/linked_account.dart';
import 'package:app/core/models/auth/oauth_provider.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/core/widgets/form_page.dart';
import 'package:app/features/auth/presentation/widgets/oauth_buttons.dart';

/// Profile, Linked accounts: one row per provider, linked or not.
///
/// Stateless: the page owns the store and the busy flag, so a link in
/// flight also locks the rest of the form (one request at a time, as
/// everywhere else on that page).
class LinkedAccountsSection extends StatelessWidget {
  final ItemState<LinkedAccounts> state;

  /// Providers this build can open a login window for.
  final Set<OAuthProvider> linkable;

  /// The row whose request is in flight, for its spinner.
  final OAuthProvider? inFlight;

  /// Null disables every button (some request is running).
  final void Function(OAuthProvider provider)? onLink;
  final void Function(OAuthProvider provider)? onUnlink;
  final VoidCallback onRetry;

  const LinkedAccountsSection({
    super.key,
    required this.state,
    required this.linkable,
    required this.inFlight,
    required this.onLink,
    required this.onUnlink,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final accounts = state.data;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Linked accounts', style: textTheme.titleMedium),
        FormGap.small,
        if (accounts != null)
          ..._rows(context, accounts)
        else if (state.error != null)
          Row(
            children: [
              const Expanded(child: Text('Could not load your linked accounts.')),
              TextButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          )
        else
          const Center(child: CircularProgressIndicator()),
      ],
    );
  }

  List<Widget> _rows(BuildContext context, LinkedAccounts accounts) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return [
      for (final provider in OAuthProvider.visible)
        _row(provider, accounts.of(provider), accounts.canUnlink),
      // Said once, under the rows, rather than as a greyed button with no
      // reason: the fix (Change password, above) is not on this row.
      if (!accounts.canUnlink && accounts.accounts.isNotEmpty)
        Text(
          'It is your only way to sign in. Set a password (Change password, above) '
          'to be able to unlink it.',
          style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
    ];
  }

  Widget _row(OAuthProvider provider, LinkedAccount? linked, bool canUnlink) {
    final available = linkable.contains(provider);
    final Widget trailing;
    if (inFlight == provider) {
      trailing = const SizedBox.square(
        dimension: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (linked != null) {
      final onUnlink = this.onUnlink;
      trailing = TextButton(
        onPressed: onUnlink == null || !canUnlink ? null : () => onUnlink(provider),
        child: const Text('Unlink'),
      );
    } else {
      final onLink = this.onLink;
      trailing = FilledButton.tonal(
        // The theme makes filled buttons full width (Size.fromHeight), which
        // a ListTile's trailing slot cannot give.
        style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
        onPressed: onLink == null || !available ? null : () => onLink(provider),
        child: const Text('Link'),
      );
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: OAuthProviderBadge(provider),
      title: Text(provider.label),
      subtitle: Text(switch ((linked, available)) {
        (LinkedAccount(:final email?), _) => email,
        (LinkedAccount(), _) => 'Linked',
        (null, true) => 'Not linked',
        (null, false) => 'Not available in this version of the app',
      }),
      trailing: trailing,
    );
  }
}
