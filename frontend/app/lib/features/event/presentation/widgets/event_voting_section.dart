import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'package:app/core/location/position_source.dart';
import 'package:app/core/models/event/event_settings.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/fitted_segment_label.dart';
import 'package:app/features/event/presentation/widgets/venue_editor.dart';
import 'package:app/features/event/presentation/widgets/venue_map.dart';

export 'package:app/features/event/presentation/widgets/venue_editor.dart' show defaultVenue;

/// Section in EventSettingsPage allowing configuration of who is allowed to vote
/// on the queue (Everyone, Invited Only, or Place & Time).
///
/// [placing]: Place & time picked, or its venue edited, and not saved yet;
/// [draft] is the venue in the editor then (null while its coordinates are
/// not a place). What it shows follows from those and [event]: the choice,
/// the venue, and whether Place & time is possible at all (the event's times).
class EventVotingSection extends StatelessWidget {
  final EventSummary event;
  final bool canManage;
  final bool busy;
  final bool placing;
  final EventVenue? draft;
  final PositionSource positions;
  final bool showMap;
  final ValueChanged<VoteChoice> onVoteChanged;
  final ValueChanged<EventVenue?> onDraftChanged;
  final ValueChanged<EventVenue> onSavePlace;

  const EventVotingSection({
    super.key,
    required this.event,
    required this.canManage,
    required this.busy,
    required this.placing,
    required this.draft,
    required this.positions,
    required this.showMap,
    required this.onVoteChanged,
    required this.onDraftChanged,
    required this.onSavePlace,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    // Shown as chosen while its venue is being set, before it is saved.
    final vote = placing ? VoteChoice.placeAndTime : VoteChoice.fromWire(event.voteLicense);
    final venue = placing ? draft : event.venue;
    // Its window is the event's own times: none, no Place & time.
    final hasWindow = voteWindowFor(event.startsAt, event.endsAt) != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _VoteLicenseSelector(
          event: event,
          vote: vote,
          venue: venue,
          hasWindow: hasWindow,
          enabled: canManage && !busy,
          onVoteChanged: onVoteChanged,
        ),
        // Where that is: the host edits it right here, and saves it; the
        // others see it on a map.
        if (vote == VoteChoice.placeAndTime && canManage) ...[
          _VenueEditorSubSection(
            event: event,
            positions: positions,
            showMap: showMap,
            busy: busy,
            placing: placing,
            draft: draft,
            onDraftChanged: onDraftChanged,
            onSavePlace: onSavePlace,
          ),
        ] else if (vote == VoteChoice.placeAndTime && event.venue != null && showMap) ...[
          _VenueMapPreviewSubSection(venue: event.venue!),
        ] else if (!hasWindow) ...[
          const SizedBox(height: AppDimens.spacingXXS),
          Text("Place & time needs the event's start and end times.", style: hint),
        ],
        if (!canManage) ...[
          const SizedBox(height: AppDimens.spacingXXS),
          Text('Only its host can change these.', style: hint),
        ],
      ],
    );
  }
}

/// Segmented button and hint text selecting who is licensed to vote.
class _VoteLicenseSelector extends StatelessWidget {
  final EventSummary event;
  final VoteChoice vote;
  final EventVenue? venue;
  final bool hasWindow;
  final bool enabled;
  final ValueChanged<VoteChoice> onVoteChanged;

  const _VoteLicenseSelector({
    required this.event,
    required this.vote,
    required this.venue,
    required this.hasWindow,
    required this.enabled,
    required this.onVoteChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Who can vote', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppDimens.spacingXS),
        SegmentedButton<VoteChoice>(
          // Three labels and a check on a phone: less padding, and a label
          // that shrinks rather than wrap (FittedSegmentLabel).
          style: SegmentedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 4),
          ),
          segments: [
            ButtonSegment(
              value: VoteChoice.everyone,
              label: FittedSegmentLabel(VoteChoice.everyone.label),
            ),
            ButtonSegment(
              value: VoteChoice.invited,
              label: FittedSegmentLabel(VoteChoice.invited.label),
            ),
            ButtonSegment(
              value: VoteChoice.placeAndTime,
              label: FittedSegmentLabel(VoteChoice.placeAndTime.label),
              enabled: hasWindow,
            ),
          ],
          selected: {vote},
          onSelectionChanged: enabled ? (picked) => onVoteChanged(picked.single) : null,
        ),
        const SizedBox(height: AppDimens.spacingXXS),
        Text(
          switch (vote) {
            VoteChoice.everyone => VoteLicense.everyone.description,
            VoteChoice.invited => VoteLicense.invitedOnly.description,
            VoteChoice.placeAndTime => placeAndTimeText(venue, event.startsAt, event.endsAt),
          },
          style: hint,
        ),
      ],
    );
  }
}

/// Interactive venue editor and save button for host-managed place and time voting.
class _VenueEditorSubSection extends StatelessWidget {
  final EventSummary event;
  final PositionSource positions;
  final bool showMap;
  final bool busy;
  final bool placing;
  final EventVenue? draft;
  final ValueChanged<EventVenue?> onDraftChanged;
  final ValueChanged<EventVenue> onSavePlace;

  const _VenueEditorSubSection({
    required this.event,
    required this.positions,
    required this.showMap,
    required this.busy,
    required this.placing,
    required this.draft,
    required this.onDraftChanged,
    required this.onSavePlace,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppDimens.spacingS),
        VenueEditor(
          // A saved venue starts the editor over from it.
          key: ValueKey(event.venue),
          initial: event.venue ?? defaultVenue,
          positions: positions,
          showMap: showMap,
          enabled: !busy,
          onChanged: onDraftChanged,
        ),
        if (placing) ...[
          const SizedBox(height: AppDimens.spacingS),
          FilledButton(
            onPressed: busy || draft == null ? null : () => onSavePlace(draft!),
            child: const Text('Save the place'),
          ),
        ],
      ],
    );
  }
}

/// Static map preview showing the geofence radius for place and time voting.
class _VenueMapPreviewSubSection extends StatelessWidget {
  final EventVenue venue;

  const _VenueMapPreviewSubSection({required this.venue});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppDimens.spacingXS),
      child: VenueMap(
        key: ValueKey(venue),
        point: LatLng(venue.latitude, venue.longitude),
        radiusMeters: venue.radiusMeters,
        height: 160,
        interactive: false,
      ),
    );
  }
}
