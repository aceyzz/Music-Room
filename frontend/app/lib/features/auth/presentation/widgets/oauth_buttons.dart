import 'package:flutter/material.dart';

import 'package:app/core/models/auth/oauth_provider.dart';
import 'package:app/core/theme/app_dimens.dart';

/// One button per visible [OAuthProvider], used on sign-in. Linking from the profile
/// is a list instead (LinkedAccountsSection), since each row has a state.
///
/// Only providers in [available] are enabled; the others show
/// [unavailableHint] so nobody wonders why a button does nothing. [onPressed]
/// null disables them all, e.g. while a request is in flight.
class OAuthButtons extends StatelessWidget {
  final void Function(OAuthProvider provider)? onPressed;
  final Set<OAuthProvider> available;
  final String unavailableHint;
  final String verb;

  const OAuthButtons({
    super.key,
    required this.onPressed,
    required this.available,
    this.unavailableHint = '(not configured)',
    this.verb = 'Continue with',
  });

  @override
  Widget build(BuildContext context) {
    final providers = OAuthProvider.visible;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final provider in providers) ...[
          if (provider != providers.first) const SizedBox(height: AppDimens.spacingS),
          _OAuthButton(
            provider: provider,
            label: available.contains(provider)
                ? '$verb ${provider.label}'
                : '$verb ${provider.label} $unavailableHint',
            onPressed: onPressed == null || !available.contains(provider)
                ? null
                : () => onPressed!(provider),
          ),
        ],
      ],
    );
  }
}

class _OAuthButton extends StatelessWidget {
  final OAuthProvider provider;
  final String label;
  final VoidCallback? onPressed;

  const _OAuthButton({required this.provider, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: colorScheme.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppDimens.radiusL)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            OAuthProviderBadge(provider),
            const SizedBox(width: AppDimens.spacingS),
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
    );
  }
}

/// No brand assets in the app: a letter badge stands in for the logo.
class OAuthProviderBadge extends StatelessWidget {
  final OAuthProvider provider;

  const OAuthProviderBadge(this.provider, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        provider.badge,
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.bold,
          color: colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}
