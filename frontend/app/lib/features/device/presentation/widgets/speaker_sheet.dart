import 'package:flutter/material.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/device/user_device.dart';
import 'package:app/features/device/data/device_source.dart';
import 'package:app/features/device/presentation/delegation_error_messages.dart';

/// Opens the host's "Where the music plays" sheet over the event player: one
/// row per device on their account, the one playing ticked (subject V.2.2: a
/// licence is specific to each device). Tapping another makes it the
/// speaker; the event's playback stream then tells every app.
///
/// [speakerId] is the event's speaker now (null before the host's first
/// play), [thisDeviceId] this install's. Who may control it is in the
/// event's settings (MusicControlSection).
Future<void> showSpeakerSheet(
  BuildContext context, {
  required DelegationApi delegation,
  required String eventPublicId,
  required String userPublicId,
  required int? speakerId,
  required int? thisDeviceId,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SpeakerSheet(
        delegation: delegation,
        eventPublicId: eventPublicId,
        userPublicId: userPublicId,
        speakerId: speakerId,
        thisDeviceId: thisDeviceId,
      ),
    );

class SpeakerSheet extends StatefulWidget {
  final DelegationApi delegation;
  final String eventPublicId;
  final String userPublicId;
  final int? speakerId;
  final int? thisDeviceId;

  const SpeakerSheet({
    super.key,
    required this.delegation,
    required this.eventPublicId,
    required this.userPublicId,
    required this.speakerId,
    required this.thisDeviceId,
  });

  @override
  State<SpeakerSheet> createState() => _SpeakerSheetState();
}

class _SpeakerSheetState extends State<SpeakerSheet> {
  late Future<List<UserDevice>> _devices;

  /// The device being made the speaker: one at a time.
  int? _busyFor;

  /// The last failure, shown in the sheet: a snack bar would open under it.
  String? _error;

  @override
  void initState() {
    super.initState();
    _devices = widget.delegation.myDevices(widget.userPublicId);
  }

  Future<void> _pick(UserDevice device) async {
    if (_busyFor != null || device.id == widget.speakerId) {
      return;
    }
    setState(() {
      _busyFor = device.id;
      _error = null;
    });
    try {
      await widget.delegation.setSpeaker(widget.eventPublicId, device.publicId);
      if (mounted) Navigator.of(context).pop();
    } on AppError catch (error) {
      if (mounted) setState(() => _error = speakerErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busyFor = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text('Where the music plays', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'One of your devices plays the sound; on the others, the event is a remote. '
              'Open the event on it to hear the music.',
              style: hint,
            ),
          ),
          if (_error case final error?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(error, style: TextStyle(color: theme.colorScheme.error)),
            ),
          Flexible(
            child: FutureBuilder(
              future: _devices,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  final error = snapshot.error;
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(error is AppError
                              ? speakerErrorMessage(error)
                              : 'Your devices could not be loaded.'),
                        ),
                        TextButton(
                          onPressed: () => setState(
                              () => _devices = widget.delegation.myDevices(widget.userPublicId)),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  );
                }
                final devices = snapshot.data;
                if (devices == null) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return ListView(
                  shrinkWrap: true,
                  children: [for (final device in devices) _row(device)],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(UserDevice device) {
    final playing = device.id == widget.speakerId;
    final mine = device.id == widget.thisDeviceId;
    final busy = _busyFor == device.id;
    return ListTile(
      leading: Icon(_platformIcon(device.platform)),
      title: Text(mine ? '${device.name} (this device)' : device.name),
      subtitle: playing ? const Text('Plays the music') : null,
      selected: playing,
      trailing: busy
          ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : playing
              ? const Icon(Icons.check)
              : null,
      onTap: () => _pick(device),
    );
  }
}

IconData _platformIcon(String platform) => switch (platform) {
      'ios' || 'android' => Icons.smartphone,
      'web' => Icons.public,
      _ => Icons.computer,
    };
