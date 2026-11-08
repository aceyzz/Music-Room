import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/user/friend_request.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/core/models/user/user_summary.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/busy_state.dart';
import 'package:app/core/widgets/inline_spinner.dart';
import 'package:app/core/widgets/search_field.dart';
import 'package:app/core/widgets/section_header.dart';
import 'package:app/core/widgets/section_placeholder.dart';
import 'package:app/core/widgets/user_tile.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/user/data/user_source.dart';
import 'package:app/features/user/presentation/stores/friends_store.dart';
import 'package:app/globals/app_router.dart';

/// The friends page (`/friends`), reached from the Home friends row: a search
/// for anyone by name, and below it, while nothing is typed, the signed-in
/// user's people in four sections:
///
/// | section  | shown                     | inline action    |
/// | -------- | ------------------------- | ---------------- |
/// | Requests | when not empty            | Accept, Decline  |
/// | Sent     | when not empty            | none (no cancel) |
/// | Friends  | always                    | none             |
/// | Blocked  | when not empty, collapsed | Unblock          |
///
/// Every person opens their profile (`/users/:id`), which has the full set of
/// actions; coming back reloads the sections, since that page may have
/// changed the relationship.
class FriendsPage extends StatefulWidget {
  const FriendsPage({super.key});

  @override
  State<FriendsPage> createState() => _FriendsPageState();
}

class _FriendsPageState extends State<FriendsPage> with BusyState<FriendsPage> {
  late final FriendsStore _store;
  final _search = TextEditingController();

  /// The inline action in flight ("accept 7", "unblock" + public id), so only its
  /// own row shows the spinner.
  String? _running;

  @override
  void initState() {
    super.initState();
    // The router only lets a signed-in user reach this page.
    _store = FriendsStore(context.read<SocialApi>(), context.currentUserId)..start();
  }

  @override
  void dispose() {
    _store.stop();
    _search.dispose();
    super.dispose();
  }

  void _onSearch(String text) {
    _store.search(text);
    setState(() {}); // the results replace the sections, or the reverse
  }

  Future<void> _open(String publicId) async {
    await context.push(userPath(publicId));
    if (mounted) {
      await Future.wait([_store.refresh(), _store.reloadResults()]);
    }
  }

  Future<void> _do(String key, Future<void> Function() call) async {
    setState(() => _running = key);
    await run(call, message: _errorMessage);
    if (mounted) {
      setState(() => _running = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Friends')),
      body: Column(
        children: [
          const SizedBox(height: AppDimens.spacingXS),
          SearchField(
            controller: _search,
            onChanged: _onSearch,
            hintText: 'Search people by name',
          ),
          Expanded(child: _store.query.isEmpty ? _sections() : _results()),
        ],
      ),
    );
  }

  Widget _results() {
    return ValueListenableBuilder(
      valueListenable: _store.results,
      builder: (context, state, _) => _SearchResults(
        state: state,
        query: _store.query,
        answered: _store.resultsQuery == _store.query,
        onOpen: _open,
        onRetry: _store.reloadResults,
      ),
    );
  }

  Widget _sections() {
    return ListenableBuilder(
      listenable: Listenable.merge(
        [_store.incoming, _store.outgoing, _store.friends, _store.blocked],
      ),
      builder: (context, _) {
        final incoming = _store.incoming.value;
        final outgoing = _store.outgoing.value;
        final blocked = _store.blocked.value;
        return RefreshIndicator(
          onRefresh: _store.refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: AppDimens.listBottomPadding,
            children: [
              ..._requestsSection(incoming),
              ..._sentSection(outgoing),
              _friendsSection(),
              _blockedSection(blocked),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _requestsSection(ListState<FriendRequest> state) => _optionalSection(
        title: 'Requests',
        state: state,
        onRetry: _store.reloadIncoming,
        row: (request) => UserTile(
          name: request.user.displayName,
          avatarUrl: request.user.avatarUrl,
          subtitle: 'Wants to be your friend',
          onTap: () => _open(request.user.publicId),
          actions: _RequestActions(
            busy: busy,
            running: _running,
            request: request,
            onAccept: () => _do('accept ${request.id}', () => _store.accept(request)),
            onDecline: () => _do('decline ${request.id}', () => _store.decline(request)),
          ),
        ),
      );

  List<Widget> _sentSection(ListState<FriendRequest> state) => _optionalSection(
        title: 'Sent',
        state: state,
        onRetry: _store.reloadOutgoing,
        row: (request) => UserTile(
          name: request.user.displayName,
          avatarUrl: request.user.avatarUrl,
          onTap: () => _open(request.user.publicId),
          trailing: Text(
            'Request sent',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      );

  Widget _blockedSection(ListState<UserSummary> state) {
    if (state.data?.isNotEmpty ?? false) {
      return _BlockedSection(
        users: state.data!,
        busy: busy,
        running: _running,
        onOpen: _open,
        onUnblock: (user) => _do('unblock ${user.publicId}', () => _store.unblock(user)),
      );
    }
    if (state.hasError) {
      return _SectionError(
        title: 'Blocked',
        error: state.error!,
        onRetry: _store.reloadBlocked,
      );
    }
    return const SizedBox.shrink();
  }

  /// A section that is left out while it has nothing to show: still loading
  /// for the first time, or empty. A failure still shows, with a retry.
  List<Widget> _optionalSection<T>({
    required String title,
    required ListState<T> state,
    required Future<void> Function() onRetry,
    required Widget Function(T item) row,
  }) {
    final items = state.data;
    if (items != null && items.isNotEmpty) {
      return [
        SectionHeader(title: title, count: items.length),
        for (final item in items) row(item),
      ];
    }
    if (state.hasError) {
      return [_SectionError(title: title, error: state.error!, onRetry: onRetry)];
    }
    return const [];
  }

  Widget _friendsSection() {
    final state = _store.friends.value;
    final List<FriendSummary>? friends = state.data;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title: 'Friends', count: friends?.length),
        if (friends != null && friends.isNotEmpty)
          for (final friend in friends)
            UserTile(
              name: friend.displayName,
              avatarUrl: friend.avatarUrl,
              onTap: () => _open(friend.publicId),
            )
        else if (state.hasError)
          SectionPlaceholder.error(state.error!, height: 80, onRetry: _store.reloadFriends)
        else if (friends == null)
          const SectionPlaceholder.loading(height: 80)
        else
          const SectionPlaceholder.message(
            'No friends yet. Search for someone above.',
            height: 80,
          ),
      ],
    );
  }
}

String _errorMessage(AppError error) => switch (error) {
      NetworkError() => 'Cannot reach the server. Check your connection.',
      // Accept or Decline on a request the other person cancelled by
      // blocking, or that was answered from another device.
      NotFoundError() => 'That request was already answered.',
      _ => 'Something went wrong. Please try again.',
    };


class _SectionError extends StatelessWidget {
  final String title;
  final AppError error;
  final VoidCallback onRetry;

  const _SectionError({required this.title, required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title: title),
        SectionPlaceholder.error(error, height: 80, onRetry: onRetry),
      ],
    );
  }
}

class _RequestActions extends StatelessWidget {
  final bool busy;
  final String? running;
  final FriendRequest request;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const _RequestActions({
    required this.busy,
    required this.running,
    required this.request,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    if (running == 'accept ${request.id}' || running == 'decline ${request.id}') {
      return const InlineSpinner();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.tonal(
          onPressed: busy ? null : onAccept,
          // The theme makes filled buttons full width (Size.fromHeight), for
          // forms; in a row that width is infinite and the row cannot be laid
          // out at all -- in a release build the buttons just vanish.
          style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
          child: const Text('Accept'),
        ),
        const SizedBox(width: AppDimens.spacingXS),
        OutlinedButton(onPressed: busy ? null : onDecline, child: const Text('Decline')),
      ],
    );
  }
}

/// Collapsed by default: it is rarely what the page is opened for.
class _BlockedSection extends StatelessWidget {
  final List<UserSummary> users;
  final bool busy;
  final String? running;
  final ValueChanged<String> onOpen;
  final ValueChanged<UserSummary> onUnblock;

  const _BlockedSection({
    required this.users,
    required this.busy,
    required this.running,
    required this.onOpen,
    required this.onUnblock,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppDimens.spacingS),
      child: ExpansionTile(
        title: Text('Blocked (${users.length})'),
        subtitle: const Text('They cannot see you or send you requests.'),
        shape: const Border(),
        children: [
          for (final user in users)
            UserTile(
              name: user.displayName,
              avatarUrl: user.avatarUrl,
              onTap: () => onOpen(user.publicId),
              // Unblocking does not make anyone friends again, so it needs
              // no "are you sure?", the same as on the profile page.
              trailing: running == 'unblock ${user.publicId}'
                  ? const InlineSpinner()
                  : TextButton(
                      onPressed: busy ? null : () => onUnblock(user),
                      child: const Text('Unblock'),
                    ),
            ),
        ],
      ),
    );
  }
}

/// What the page shows while something is typed, instead of the sections.
class _SearchResults extends StatelessWidget {
  final ListState<UserSummary> state;
  final String query;

  /// Whether [state] answers [query]: false while the search waits for typing
  /// to pause, or is in flight.
  final bool answered;

  final ValueChanged<String> onOpen;
  final Future<void> Function() onRetry;

  const _SearchResults({
    required this.state,
    required this.query,
    required this.answered,
    required this.onOpen,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final users = state.data;
    if (users == null) {
      if (state.hasError) {
        return SectionPlaceholder.error(state.error!, height: 120, onRetry: onRetry);
      }
      return const Center(child: CircularProgressIndicator());
    }
    if (users.isEmpty) {
      return answered
          ? SectionPlaceholder.message('No one matches "$query".', height: 120)
          : const Center(child: CircularProgressIndicator());
    }
    final theme = Theme.of(context);
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        for (final user in users)
          UserTile(
            name: user.displayName,
            avatarUrl: user.avatarUrl,
            onTap: () => onOpen(user.publicId),
          ),
        // The server sends no more than asked and has no paging.
        if (!state.hasReachedEnd)
          Padding(
            padding: const EdgeInsets.all(AppDimens.spacingM),
            child: Text(
              'Showing the first ${users.length}. Keep typing to narrow it down.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
