import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/widgets/user_avatar.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/user/presentation/stores/current_user_store.dart';
import 'package:app/globals/app_router.dart';

/// The signed-in user's picture and name, opening their profile. In the top
/// bar of every tab (MainAppBar).
///
/// The name comes from the session until the profile has loaded, and the
/// picture falls back to initials, so the button is never empty.
class ProfileButton extends StatelessWidget {
  const ProfileButton({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.read<SessionStore>().state.value;
    return ValueListenableBuilder(
      valueListenable: context.read<CurrentUserStore>().profile,
      builder: (context, profile, _) {
        final name = profile?.displayName ??
            switch (session) {
              SignedIn(:final user) => user.displayName,
              SignedOut() => '', // the frame before the router leaves the tabs
            };
        return Semantics(
          button: true,
          label: 'Your profile',
          excludeSemantics: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: () => context.push(profileRoute),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  UserAvatar(url: profile?.avatarUrl, name: name, radius: 16),
                  const SizedBox(width: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(
                      name,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
