import 'package:flutter/material.dart';

import 'package:app/features/user/presentation/widgets/profile_button.dart';

/// The top bar of each tab's first page: the user's profile on the left.
/// Delegating control of the music lives in the event player, the one place
/// with a shared player.
///
/// Each tab page puts it in its own Scaffold rather than MainShell owning one
/// bar for all, so a page pushed inside a tab can have its own bar (with a
/// back arrow) while the tabs stay.
///
/// A tab whose list can go stale passes [onRefresh] for a refresh button.
/// Its list has pull-to-refresh too, but that is a touch gesture: a mouse
/// (desktop, the noVNC phone) cannot pull.
class MainAppBar extends StatelessWidget implements PreferredSizeWidget {
  final VoidCallback? onRefresh;

  const MainAppBar({super.key, this.onRefresh});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      automaticallyImplyLeading: false,
      centerTitle: false,
      titleSpacing: 8,
      title: const Align(alignment: Alignment.centerLeft, child: ProfileButton()),
      actions: [
        if (onRefresh != null)
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: onRefresh,
          ),
      ],
    );
  }
}
