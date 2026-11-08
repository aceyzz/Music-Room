import 'dart:async';

import 'package:flutter/material.dart';

import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/widgets/track_tile.dart';

/// The seek bar, with the time played and the song's length under it.
///
/// The server only gives the playhead as of its last answer
/// ([EventPlayback.positionAt]), so this repaints itself four times a second
/// while the song plays. Dragging shows where the thumb is; letting go calls
/// [onSeek] (null disables the bar).
class PlaybackProgress extends StatefulWidget {
  final EventPlayback playback;
  final ValueChanged<Duration>? onSeek;
  final DateTime Function() now;

  const PlaybackProgress({
    super.key,
    required this.playback,
    required this.onSeek,
    this.now = DateTime.now,
  });

  @override
  State<PlaybackProgress> createState() => _PlaybackProgressState();
}

/// Repaints four times a second while [playback] plays, since the server
/// only gives the playhead as of its last answer. A paused or empty player
/// costs nothing.
mixin _FollowsPlayhead<T extends StatefulWidget> on State<T> {
  EventPlayback get playback;

  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _tick();
  }

  @override
  void didUpdateWidget(T old) {
    super.didUpdateWidget(old);
    _tick();
  }

  void _tick() {
    _ticker?.cancel();
    _ticker = playback.isPlaying
        ? Timer.periodic(const Duration(milliseconds: 250), (_) => setState(() {}))
        : null;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

class _PlaybackProgressState extends State<PlaybackProgress>
    with _FollowsPlayhead<PlaybackProgress> {
  @override
  EventPlayback get playback => widget.playback;

  /// Where the thumb is while being dragged; null otherwise.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final length = widget.playback.track?.duration ?? Duration.zero;
    final lengthMs = length.inMilliseconds.toDouble();
    final positionMs = _dragging ??
        widget.playback.positionAt(widget.now()).inMilliseconds.toDouble().clamp(0.0, lengthMs);
    final onSeek = widget.onSeek;
    final enabled = onSeek != null && lengthMs > 0;
    final labelStyle =
        theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      children: [
        Slider(
          value: lengthMs > 0 ? positionMs : 0,
          max: lengthMs > 0 ? lengthMs : 1,
          onChanged: enabled ? (value) => setState(() => _dragging = value) : null,
          onChangeEnd: enabled
              ? (value) {
                  setState(() => _dragging = null);
                  onSeek(Duration(milliseconds: value.round()));
                }
              : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(formatTrackDuration(Duration(milliseconds: positionMs.round())), style: labelStyle),
              Text(formatTrackDuration(length), style: labelStyle),
            ],
          ),
        ),
      ],
    );
  }
}

/// Where the song is, for those who cannot move it: a thin bar with the time
/// played and the song's length. Not a disabled [Slider], which still looks
/// like something to drag.
class PlaybackBar extends StatefulWidget {
  final EventPlayback playback;
  final DateTime Function() now;

  const PlaybackBar({super.key, required this.playback, this.now = DateTime.now});

  @override
  State<PlaybackBar> createState() => _PlaybackBarState();
}

class _PlaybackBarState extends State<PlaybackBar> with _FollowsPlayhead<PlaybackBar> {
  @override
  EventPlayback get playback => widget.playback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final length = widget.playback.track?.duration ?? Duration.zero;
    var position = widget.playback.positionAt(widget.now());
    if (position < Duration.zero) {
      position = Duration.zero;
    } else if (position > length) {
      position = length;
    }
    final labelStyle =
        theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Row(
      children: [
        Text(formatTrackDuration(position), style: labelStyle),
        const SizedBox(width: 8),
        Expanded(
          child: LinearProgressIndicator(
            value: length > Duration.zero ? position.inMilliseconds / length.inMilliseconds : 0,
            minHeight: 4,
            borderRadius: BorderRadius.circular(2),
            semanticsLabel: 'Song progress',
          ),
        ),
        const SizedBox(width: 8),
        Text(formatTrackDuration(length), style: labelStyle),
      ],
    );
  }
}

/// Previous (restart), play / pause, next. [onPrevious] etc. null disables
/// the button: while a command is in flight, or when there is no song to act
/// on.
class PlaybackControls extends StatelessWidget {
  final bool isPlaying;
  final VoidCallback? onPrevious;
  final VoidCallback? onPlayPause;
  final VoidCallback? onNext;

  const PlaybackControls({
    super.key,
    required this.isPlaying,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          iconSize: 40,
          tooltip: 'Restart',
          onPressed: onPrevious,
          icon: const Icon(Icons.skip_previous_rounded),
        ),
        const SizedBox(width: 16),
        IconButton.filled(
          iconSize: 48,
          tooltip: isPlaying ? 'Pause' : 'Play',
          onPressed: onPlayPause,
          icon: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
        ),
        const SizedBox(width: 16),
        IconButton(
          iconSize: 40,
          tooltip: 'Next',
          onPressed: onNext,
          icon: const Icon(Icons.skip_next_rounded),
        ),
      ],
    );
  }
}
