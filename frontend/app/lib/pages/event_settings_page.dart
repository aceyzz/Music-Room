import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/location/position_source.dart';
import 'package:app/core/models/event/event_details.dart';
import 'package:app/core/models/event/event_settings.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/busy_state.dart';
import 'package:app/core/widgets/confirm_dialog.dart';
import 'package:app/core/widgets/danger_action_button.dart';
import 'package:app/core/widgets/invite_friend_sheet.dart';
import 'package:app/core/widgets/settings_members_section.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/device/data/device_source.dart';
import 'package:app/features/device/presentation/stores/device_store.dart';
import 'package:app/features/device/presentation/widgets/music_control_section.dart';
import 'package:app/features/event/data/event_source.dart';
import 'package:app/features/event/presentation/stores/event_settings_store.dart';
import 'package:app/features/event/presentation/widgets/event_visibility_section.dart';
import 'package:app/features/event/presentation/widgets/event_voting_section.dart';
import 'package:app/features/user/data/user_source.dart';
import 'package:app/globals/app_router.dart';

/// An event's settings (`/events/:id/settings`), opened from its page: who
/// can find it, who can vote, and its people (subject V.2.1), with the
/// host's music-control switches on their friends (V.2.2).
///
/// Everyone who can open the event sees all of it; the host changes the
/// settings and ends it, invited people may invite too. The server checks
/// each change again.
///
/// Pops with true once the event is ended, so its page closes as well.
class EventSettingsPage extends StatefulWidget {
  final String publicId;

  /// A parameter for tests: where the phone is, for "Use my position".
  /// Defaults to [platformPositionSource].
  final PositionSource? positions;

  /// A parameter for tests, which have no network for the map's tiles.
  final bool showMap;

  const EventSettingsPage({
    super.key,
    required this.publicId,
    this.positions,
    this.showMap = true,
  });

  @override
  State<EventSettingsPage> createState() => _EventSettingsPageState();
}

class _EventSettingsPageState extends State<EventSettingsPage> with BusyState<EventSettingsPage> {
  // ---------------------------------------------------------------------------
  // State Variables
  // ---------------------------------------------------------------------------

  late final EventSettingsStore _store;
  late final String _userPublicId;
  late final PositionSource _positions = widget.positions ?? platformPositionSource();

  /// Place & time picked, or its venue edited, and not saved yet: the venue
  /// as it stands in the editor (null while its coordinates are not a
  /// place). [_placing] false: nothing pending.
  bool _placing = false;
  EventVenue? _draft;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    // The router only lets a signed-in user reach this page.
    _userPublicId = context.currentUserId;
    _store = EventSettingsStore(
      context.read<EventInfoApi>(),
      context.read<EventSettingsApi>(),
      context.read<SocialApi>(),
      widget.publicId,
      _userPublicId,
    )..start();
  }

  @override
  void dispose() {
    _store.stop();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  /// Opens the friend invitation bottom sheet.
  Future<void> _invite() async {
    final List<FriendSummary> friends;
    try {
      friends = await _store.invitableFriends();
    } on AppError catch (error) {
      showError(_errorMessage(error));
      return;
    }
    if (!mounted) {
      return;
    }
    final picked = await showModalBottomSheet<FriendSummary>(
      context: context,
      showDragHandle: true,
      builder: (context) => InviteFriendSheet(friends: friends),
    );
    if (picked != null && await run(() => _store.invite(picked), message: _errorMessage)) {
      showInfo('${picked.displayName} is invited now.');
    }
  }

  /// Saves the venue in the editor, with the event's own times as the
  /// window; the licence becomes Place & time if it was not.
  Future<void> _savePlace(EventVenue venue) async {
    if (await run(() => _store.setPlaceAndTime(venue), message: _errorMessage) && mounted) {
      setState(() => _placing = false);
    }
  }

  /// Updates the event voting license.
  void _setLicense(VoteLicense license) {
    setState(() => _placing = false);
    run(() => _store.setVoteLicense(license), message: _errorMessage);
  }

  /// Prompts confirmation and permanently ends the event.
  Future<void> _end(String name) async {
    final sure = await showConfirmDialog(
      context,
      title: 'End $name?',
      content: 'The music stops for everyone and it leaves the lists. '
          'This cannot be undone.',
      confirmLabel: 'End',
    );
    if (sure && await run(_store.end, message: _errorMessage) && mounted) {
      // Opened from its page, which closes too; reached directly (a link),
      // the events list is what is left.
      context.canPop() ? context.pop(true) : context.go(eventsRoute);
    }
  }

  // ---------------------------------------------------------------------------
  // Computed Views (Subviews)
  // ---------------------------------------------------------------------------

  /// Event title display.
  Widget _header(EventSummary event) =>
      Text(event.name, style: Theme.of(context).textTheme.titleLarge);

  /// Discovery visibility section (Public / Private).
  Widget _visibilitySection(EventSummary event) => EventVisibilitySection(
        visibility: event.visibility,
        enabled: _canManage,
        onChanged: (v) => run(() => _store.setVisibility(v), message: _errorMessage),
      );

  /// Voting license and venue configuration section.
  Widget _votingSection(EventSummary event) {
    return EventVotingSection(
      event: event,
      canManage: _store.canManage,
      busy: busy,
      placing: _placing,
      draft: _draft,
      positions: _positions,
      showMap: widget.showMap,
      onVoteChanged: (choice) => switch (choice) {
        VoteChoice.everyone => _setLicense(VoteLicense.everyone),
        VoteChoice.invited => _setLicense(VoteLicense.invitedOnly),
        VoteChoice.placeAndTime => setState(() {
            _placing = true;
            _draft = event.venue ?? defaultVenue;
          }),
      },
      onDraftChanged: (edited) => setState(() {
        _placing = true;
        _draft = edited;
      }),
      onSavePlace: _savePlace,
    );
  }

  /// Invited members and host list section; for the host, a music-control
  /// switch on each of their friends ([_musicControl]).
  Widget _membersSection(EventSummary event) => SettingsMembersSection<EventMember>(
        members: _store.members.value.data,
        hasError: _store.members.value.hasError,
        currentUserId: _userPublicId,
        canInvite: _store.canInvite,
        onInvite: busy ? null : _invite,
        displayName: (m) => m.displayName,
        avatarUrl: (m) => m.avatarUrl,
        publicId: (m) => m.publicId,
        roleLabel: (m) => m.role == 'owner' ? 'Host' : 'Invited',
        list: _musicControl(event),
      );

  /// The invited people with a music-control switch on each of the host's
  /// friends (subject V.2.2), for the host while the event is on: null
  /// otherwise, and without what it needs (a registered device, the
  /// delegation and playback APIs), as in tests that leave them out.
  Widget Function(List<EventMember>, Widget Function(EventMember, Widget?))? _musicControl(
      EventSummary event) {
    final delegation = context.read<DelegationApi?>();
    final live = context.read<LiveEventApi?>();
    final device = context.read<DeviceStore?>();
    if (!_store.canManage || event.status == 'ended' ||
        delegation == null || live == null || device == null) {
      return null;
    }
    return (members, tile) => MusicControlSection(
          delegation: delegation,
          social: context.read<SocialApi>(),
          live: live,
          eventPublicId: widget.publicId,
          userPublicId: _userPublicId,
          thisDeviceId: device.deviceId.value,
          members: members,
          tile: tile,
        );
  }

  /// Destructive action button to end the event.
  Widget? _endButton(EventSummary event) {
    if (!_store.canEnd || event.status == 'ended') {
      return null;
    }
    return DangerActionButton(
      icon: Icons.stop_circle_outlined,
      label: 'End event',
      onPressed: busy ? null : () => _end(event.name),
    );
  }

  /// Scrollable list layout of all settings sections.
  Widget _settingsList(EventSummary event) {
    final endButton = _endButton(event);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: AppDimens.settingsPagePadding,
      children: [
        _header(event),
        const SizedBox(height: AppDimens.spacingM),
        _visibilitySection(event),
        const SizedBox(height: AppDimens.spacingM),
        _votingSection(event),
        const SizedBox(height: AppDimens.spacingL),
        _membersSection(event),
        if (endButton != null) endButton,
      ],
    );
  }

  /// True when the user is host and no async action is running.
  bool get _canManage => _store.canManage && !busy;

  /// Main body handling loading, error, and loaded states.
  Widget get _body {
    final state = _store.event.value;
    final event = state.data;
    if (event == null) {
      return state.hasError
          ? Center(
              child: TextButton(
                onPressed: _store.refresh,
                child: const Text('Try again'),
              ),
            )
          : const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _store.refresh,
      child: _settingsList(event),
    );
  }

  // ---------------------------------------------------------------------------
  // Main Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Event settings')),
      body: ListenableBuilder(
        listenable: Listenable.merge([_store.event, _store.members]),
        builder: (context, _) => _body,
      ),
    );
  }
}

String _errorMessage(AppError error) => switch (error) {
      UnauthorizedError() => "You can't change this event.",
      NotFoundError() => 'This event or this person no longer exists.',
      NetworkError() => 'Cannot reach the server. Check your connection.',
      _ => 'Something went wrong. Please try again.',
    };
