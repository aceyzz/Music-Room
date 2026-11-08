import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:app/core/models/event/event_details.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/core/widgets/playlist_cover.dart';
import 'package:app/core/widgets/search_field.dart';
import 'package:app/core/widgets/track_tile.dart';
import 'package:app/core/widgets/user_avatar.dart';
import 'package:app/features/event/presentation/widgets/event_player.dart';
import 'package:app/globals/app_router.dart';

/// The page of a live event, the same for everyone: what plays, then the
/// queue with a ballot button on each song. The person in control (the host,
/// for now) also gets the player's buttons in the banner ([controls]).
///
/// Two parts:
/// - the "Now playing" banner, fixed at the top. Outside the scroll view
///   rather than a pinned sliver: a [SliverFloatingHeader] slides in at the
///   top of the viewport whatever is pinned there, so it would come back
///   hidden under the banner;
/// - under it, one scroll view: the search, floating — it scrolls away with
///   the list and slides back in, over the songs, as soon as the user scrolls
///   up, wherever they are in the list. Frosted (a blur behind a see-through
///   fill), so the songs stay visible as they pass under it — and the songs.
///
/// The search filters the songs already on screen, on each keystroke: there
/// is no request to save, so none of the 300 ms wait the server searches use.
///
/// The button never says "Vote": the ballot icon carries it, and screen
/// readers get the words through its semantic label.
///
/// Adding a song is the page's floating + ([onSuggest] with no text); a
/// search of the queue that finds nothing offers to look the same words up
/// on Deezer ([onSuggest] with them).
class VoteView extends StatefulWidget {
  final ValueListenable<ItemState<EventPlayback>> playback;
  final ValueListenable<ListState<QueueEntry>> queue;

  /// A vote is in flight: every button waits for it.
  final bool busy;
  final ValueChanged<QueueEntry> onVote;
  final Future<void> Function() onRefresh;

  /// Opens the suggest sheet, searching the given text.
  final ValueChanged<String> onSuggest;

  /// The player's buttons, for the people in control; null for everyone
  /// else.
  final PlayerActions? controls;

  /// Whether this app plays the sound (LiveEventStore.playsHere). When it
  /// does not, the banner says it plays on the host's device, so a guest, or
  /// a friend holding the controls, hearing nothing does not think the app is
  /// broken. Defaults to "whoever has the buttons plays it".
  final bool? playsHere;

  /// Who hosts it: a guest sees their face and name ("Waiting for Sarah to
  /// press play"). Null inside: not read yet, so "the host".
  final ValueListenable<EventMember?>? host;

  /// Why the user may not vote or suggest, said above the songs; null when
  /// they may. Then the ballots are greyed out.
  final String? cannotVote;

  /// A parameter for tests: the progress bar runs on it.
  final DateTime Function() now;

  const VoteView({
    super.key,
    required this.playback,
    required this.queue,
    required this.busy,
    required this.onVote,
    required this.onRefresh,
    required this.onSuggest,
    this.controls,
    this.playsHere,
    this.host,
    this.cannotVote,
    this.now = DateTime.now,
  });

  @override
  State<VoteView> createState() => _VoteViewState();
}

class _VoteViewState extends State<VoteView> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(QueueEntry entry) {
    if (_query.isEmpty) {
      return true;
    }
    return entry.track.title.toLowerCase().contains(_query) ||
        entry.track.artist.toLowerCase().contains(_query);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListenableBuilder(
          listenable: Listenable.merge([widget.playback, widget.host]),
          builder: (context, _) => _NowPlayingBanner(
            playback: widget.playback.value.data,
            controls: widget.controls,
            playsHere: widget.playsHere ?? widget.controls != null,
            host: widget.host?.value,
            now: widget.now,
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: widget.onRefresh,
            child: CustomScrollView(
              // A short queue still pulls to refresh, and still scrolls the
              // search away.
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverFloatingHeader(
                  child: _FrostedSearch(
                    controller: _search,
                    onChanged: (text) => setState(() => _query = text.trim().toLowerCase()),
                  ),
                ),
                if (widget.cannotVote case final reason?)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text(
                        reason,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                ValueListenableBuilder<ListState<QueueEntry>>(
                  valueListenable: widget.queue,
                  builder: (context, state, _) => _songs(context, state),
                ),
                // Room for the page's floating +, so it never hides the last
                // song's ballot.
                const SliverToBoxAdapter(child: SizedBox(height: 88)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _songs(BuildContext context, ListState<QueueEntry> state) {
    final entries = state.data;
    if (entries == null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: state.hasError
                ? const Text('The queue could not be loaded. Pull to retry.')
                : const CircularProgressIndicator(),
          ),
        ),
      );
    }
    final shown = entries.where(_matches).toList();
    if (shown.isEmpty) {
      final typed = _search.text.trim();
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            children: [
              Text(
                entries.isEmpty
                    ? widget.cannotVote == null
                        ? 'Nothing queued yet. Add a song with +.'
                        : 'Nothing queued yet.'
                    : 'No song matches "$typed".',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              if (entries.isNotEmpty && widget.cannotVote == null) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => widget.onSuggest(typed),
                  child: Text('Search Deezer for "$typed"'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return SliverList.builder(
      itemCount: shown.length,
      itemBuilder: (context, i) => VoteTile(
        // Keyed by song: the list reorders as the votes come in.
        key: ValueKey(shown[i].publicId),
        entry: shown[i],
        canVote: widget.cannotVote == null,
        onVote: widget.busy || shown[i].viewerHasVoted ? null : () => widget.onVote(shown[i]),
      ),
    );
  }
}

/// What the person in control can do from the banner. A null action is a
/// disabled button: a command in flight, or no song to act on.
class PlayerActions {
  final VoidCallback? restart;
  final VoidCallback? playPause;
  final VoidCallback? next;
  final ValueChanged<Duration>? seek;

  const PlayerActions({this.restart, this.playPause, this.next, this.seek});
}

/// The song playing, small: cover, title and artist, and where it is. With
/// [controls], restart / play-pause / next beside it, and a bar to drag.
class _NowPlayingBanner extends StatelessWidget {
  final EventPlayback? playback;
  final PlayerActions? controls;
  final bool playsHere;
  final EventMember? host;
  final DateTime Function() now;

  const _NowPlayingBanner({
    required this.playback,
    required this.controls,
    required this.playsHere,
    required this.host,
    required this.now,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playback = this.playback;
    final track = playback?.track;
    final controls = this.controls;
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final host = this.host;
    final hostName = host?.displayName ?? 'the host';
    // The host's face, small, beside what is said about them; a speaker icon
    // until they are known. A tap opens their profile, as on a playlist page.
    final hostId = host?.publicId;
    Widget hostLine(String text) => InkWell(
          onTap: hostId == null ? null : () => context.push(userPath(hostId)),
          child: Row(
            children: [
              host == null
                  ? Icon(Icons.volume_up_outlined, size: 16, color: muted?.color)
                  : UserAvatar(url: host.avatarUrl, name: host.displayName, radius: 9),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted?.color),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'NOW PLAYING',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox.square(
                    dimension: 56,
                    child: PlaylistCover(url: track?.coverUrl, iconSize: 28),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track?.title ?? 'Nothing is playing yet',
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // Nothing starts on its own: the host's play does.
                      if (track == null && controls == null)
                        hostLine('Waiting for $hostName to press play')
                      else
                        Text(
                          track?.artist ?? 'Press play to start the most-voted song',
                          style: muted,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                if (controls != null) ...[
                  IconButton(
                    tooltip: 'Restart',
                    onPressed: track == null ? null : controls.restart,
                    icon: const Icon(Icons.skip_previous_rounded),
                  ),
                  IconButton.filled(
                    tooltip: playback?.isPlaying ?? false ? 'Pause' : 'Play',
                    onPressed: controls.playPause,
                    icon: Icon(playback?.isPlaying ?? false
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded),
                  ),
                  IconButton(
                    tooltip: 'Next',
                    onPressed: controls.next,
                    icon: const Icon(Icons.skip_next_rounded),
                  ),
                ],
              ],
            ),
            if (playback != null && track != null) ...[
              const SizedBox(height: 8),
              if (controls != null)
                PlaybackProgress(playback: playback, onSeek: controls.seek, now: now)
              else
                PlaybackBar(playback: playback, now: now),
              if (!playsHere) ...[
                const SizedBox(height: 6),
                // A paused song stays where it was: the bar does not move.
                hostLine(
                  '${playback.isPaused ? 'Paused' : 'Playing'} on '
                  "${host == null ? 'the host' : host.displayName}'s device",
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// The search box on frosted glass.
class _FrostedSearch extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _FrostedSearch({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    // ClipRect bounds the blur to the header; without it the filter applies
    // to everything painted under it up to the screen's edge.
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: ColoredBox(
          color: surface.withValues(alpha: 0.72),
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Material(
              type: MaterialType.transparency,
              child: SearchField(
                controller: controller,
                onChanged: onChanged,
                hintText: 'Search this queue',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One song in the queue: cover, title, artist, its votes and the ballot
/// button. [onVote] null disables the button: already voted (there is no
/// un-vote), or a vote in flight; without [canVote] it is greyed out too.
class VoteTile extends StatelessWidget {
  final QueueEntry entry;
  final VoidCallback? onVote;
  final bool canVote;

  const VoteTile({super.key, required this.entry, required this.onVote, this.canVote = true});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final voted = entry.viewerHasVoted;
    final votes = entry.voteCount;
    return TrackTile(
      title: entry.track.title,
      artist: entry.track.artist,
      coverUrl: entry.track.coverUrl,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$votes',
            style: theme.textTheme.titleMedium?.copyWith(
              color: voted ? theme.colorScheme.primary : null,
            ),
            semanticsLabel: votes == 1 ? '1 vote' : '$votes votes',
          ),
          IconButton(
            onPressed: canVote ? onVote : null,
            // Voted is final, so the button is disabled then, but it keeps
            // the colour that says "yours".
            disabledColor: voted ? theme.colorScheme.primary : null,
            icon: Icon(
              voted ? Icons.how_to_vote : Icons.how_to_vote_outlined,
              semanticLabel:
                  voted ? 'You voted for ${entry.track.title}' : 'Vote for ${entry.track.title}',
            ),
          ),
        ],
      ),
    );
  }
}
