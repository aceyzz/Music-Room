import 'package:flutter/material.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/device/user_device.dart';
import 'package:app/core/models/event/event_details.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/features/device/data/device_source.dart';
import 'package:app/features/device/presentation/delegation_error_messages.dart';
import 'package:app/features/device/presentation/stores/event_delegates_store.dart';
import 'package:app/features/event/data/event_source.dart';
import 'package:app/features/user/data/user_source.dart';

/// The event settings' invited people, for its host, each friend among them
/// with a switch: on = they may play, pause, skip and seek the music during
/// this event (subject V.2.2). To control it, a friend is in the event: one
/// who is not is invited first.
///
/// The licences are on the device that plays, the event's speaker: the server
/// checks a delegate against it, and with no speaker lets only the host
/// control. Before the host's first play there is none yet: this device
/// stands in, and the first friend switched on makes it the speaker
/// (SetEventSpeaker). Picking another one later moves the licences along.
///
/// [tile] draws one person, with the switch when there is one: the page's own
/// row, so the list reads the same for everyone.
class MusicControlSection extends StatefulWidget {
  final DelegationApi delegation;
  final SocialApi social;
  final LiveEventApi live;
  final String eventPublicId;
  final String userPublicId;

  /// This install, which stands in for the speaker before there is one.
  final int? thisDeviceId;

  final List<EventMember> members;
  final Widget Function(EventMember member, Widget? control) tile;

  const MusicControlSection({
    super.key,
    required this.delegation,
    required this.social,
    required this.live,
    required this.eventPublicId,
    required this.userPublicId,
    required this.thisDeviceId,
    required this.members,
    required this.tile,
  });

  @override
  State<MusicControlSection> createState() => _MusicControlSectionState();
}

class _MusicControlSectionState extends State<MusicControlSection> {
  late Future<({UserDevice device, bool standsIn})?> _speaker = _findSpeaker();

  /// The event's speaker, or this device standing in ([standsIn]) while it
  /// has none.
  Future<({UserDevice device, bool standsIn})?> _findSpeaker() async {
    final (:playback, canControl: _) = await widget.live.playback(widget.eventPublicId, widget.userPublicId);
    final devices = await widget.delegation.myDevices(widget.userPublicId);
    final speakerId = playback.speakerDeviceId;
    final device = devices.where((d) => d.id == (speakerId ?? widget.thisDeviceId)).firstOrNull;
    return device == null ? null : (device: device, standsIn: speakerId == null);
  }

  /// The invited people with no switch: while the speaker is looked for, or
  /// when it cannot be.
  Widget _plain(Widget above) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [above, for (final m in widget.members) widget.tile(m, null)],
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return FutureBuilder(
      future: _speaker,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          final error = snapshot.error;
          return _plain(Row(
            children: [
              Expanded(
                child: Text(error is AppError
                    ? speakerErrorMessage(error)
                    : 'The device that plays could not be found.'),
              ),
              TextButton(
                onPressed: () => setState(() => _speaker = _findSpeaker()),
                child: const Text('Retry'),
              ),
            ],
          ));
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return _plain(const SizedBox.shrink());
        }
        final found = snapshot.data;
        if (found == null) {
          return _plain(
              Text('Open the event on one of your devices and press play first.', style: hint));
        }
        final (device: speaker, :standsIn) = found;
        return _Controls(
          // Another speaker: a store of its own.
          key: ValueKey(speaker.publicId),
          createStore: () => EventDelegatesStore(
            widget.delegation,
            widget.social,
            speaker.publicId,
            widget.eventPublicId,
            widget.userPublicId,
            beforeGrant: standsIn
                ? () => widget.delegation.setSpeaker(widget.eventPublicId, speaker.publicId)
                : null,
          ),
          hint: Text(
            standsIn
                ? 'Friends switched on can play, pause, skip and seek the music during this event. '
                    'Nothing plays it yet: switching one on makes ${speaker.name}, this device, '
                    'the one that does.'
                : 'Friends switched on can play, pause, skip and seek the music on '
                    '${speaker.name}, the device that plays it, during this event.',
            style: hint,
          ),
          members: widget.members,
          userPublicId: widget.userPublicId,
          tile: widget.tile,
        );
      },
    );
  }
}

/// The list with its switches, once the speaker is known. Owns its store:
/// makes it once, with [createStore], starts it, and stops it when it goes.
/// Once, not on every build: the page rebuilds on any setting change, and a
/// store made then would never be started -- the switches would vanish.
class _Controls extends StatefulWidget {
  final EventDelegatesStore Function() createStore;
  final Widget hint;
  final List<EventMember> members;
  final String userPublicId;
  final Widget Function(EventMember member, Widget? control) tile;

  const _Controls({
    super.key,
    required this.createStore,
    required this.hint,
    required this.members,
    required this.userPublicId,
    required this.tile,
  });

  @override
  State<_Controls> createState() => _ControlsState();
}

class _ControlsState extends State<_Controls> {
  late final EventDelegatesStore _store = widget.createStore();

  /// The friend whose switch is in flight: one at a time.
  String? _busyFor;

  /// The last switch's failure, shown under the hint, where the host tapped.
  String? _error;

  @override
  void initState() {
    super.initState();
    _store.start();
  }

  @override
  void dispose() {
    _store.stop();
    super.dispose();
  }

  Future<void> _toggle(EventDelegate delegate) async {
    if (_busyFor != null) {
      return;
    }
    setState(() {
      _busyFor = delegate.friend.publicId;
      _error = null;
    });
    try {
      await _store.toggle(delegate);
    } on AppError catch (error) {
      if (mounted) setState(() => _error = delegationErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busyFor = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder(
      valueListenable: _store.state,
      builder: (context, ItemState<List<EventDelegate>> state, _) {
        // Friends only: the server delegates to no one else.
        final byFriend = {for (final d in state.data ?? const <EventDelegate>[]) d.friend.publicId: d};
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            widget.hint,
            if (state.error case final error? when state.data == null)
              Row(
                children: [
                  Expanded(child: Text(delegationErrorMessage(error))),
                  TextButton(onPressed: _store.reload, child: const Text('Retry')),
                ],
              ),
            if (_error case final error?)
              Text(error, style: TextStyle(color: theme.colorScheme.error)),
            for (final member in widget.members)
              widget.tile(
                member,
                switch (byFriend[member.publicId]) {
                  final delegate? when member.publicId != widget.userPublicId => Switch(
                      value: delegate.licenseId != null,
                      onChanged: _busyFor == null ? (_) => _toggle(delegate) : null,
                    ),
                  _ => null,
                },
              ),
          ],
        );
      },
    );
  }
}
