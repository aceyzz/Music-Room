import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:app/core/models/event/event_settings.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/widgets/entity_badges.dart';
import 'package:app/features/event/presentation/widgets/event_tile.dart';
import 'package:app/globals/app_router.dart';

/// The Home events carousel, of the user's events (hosted or invited to). It
/// opens on what is happening now; swiping left goes forward through upcoming
/// ones.
///
/// With nothing happening, the first card says so, so the direction means
/// the same thing either way. The neighbouring cards peek in at the edges to
/// show there is more to swipe.
class EventCarousel extends StatefulWidget {
  final EventTimeline timeline;

  /// Used to word the dates ("Starts 15 Oct · 20:00"). A parameter for tests.
  final DateTime Function() now;

  /// Runs once back from an event: what happened there (a pause, the last
  /// song) changes what its card says.
  final VoidCallback? onReturn;

  static const height = 180.0;

  const EventCarousel({
    super.key,
    required this.timeline,
    this.now = DateTime.now,
    this.onReturn,
  });

  @override
  State<EventCarousel> createState() => _EventCarouselState();
}

class _EventCarouselState extends State<EventCarousel> {
  late PageController _controller;

  @override
  void initState() {
    super.initState();
    _controller = _controllerFor(widget.timeline);
  }

  @override
  void didUpdateWidget(EventCarousel old) {
    super.didUpdateWidget(old);
    // A refresh can change what is "now": open on it again.
    if (old.timeline != widget.timeline) {
      _controller.dispose();
      _controller = _controllerFor(widget.timeline);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static PageController _controllerFor(EventTimeline timeline) =>
      PageController(viewportFraction: 0.88);

  @override
  Widget build(BuildContext context) {
    final timeline = widget.timeline;
    final cards = <Widget>[
      if (timeline.current.isEmpty)
        const _NothingLiveCard()
      else
        for (final event in timeline.current)
          _EventCard(event: event, now: widget.now, onReturn: widget.onReturn),
      for (final event in timeline.upcoming)
        _EventCard(event: event, now: widget.now, onReturn: widget.onReturn),
    ];
    return SizedBox(
      height: EventCarousel.height,
      child: PageView(controller: _controller, children: cards),
    );
  }
}

class _EventCard extends StatelessWidget {
  final EventSummary event;
  final DateTime Function() now;

  final VoidCallback? onReturn;

  const _EventCard({required this.event, required this.now, this.onReturn});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final phase = event.phaseAt(now());
    final (start, end) = switch (phase) {
      EventPhase.current => (scheme.primary, scheme.tertiary),
      EventPhase.upcoming => (scheme.secondary, scheme.primary),
      EventPhase.past => (scheme.outline, scheme.onSurfaceVariant),
    };
    // White on every card: the gradients are mid-to-dark in both themes, and
    // a cover gets a dark veil under the text.
    const onCard = Colors.white;
    final cover = event.coverUrl;
    final gradient = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [start, end],
        ),
      ),
      // No song yet: a large faded note, so the card is not an empty block.
      child: Align(
        alignment: const Alignment(0.9, 0.2),
        child:
            Icon(Icons.music_note_rounded, size: 120, color: Colors.white.withValues(alpha: 0.14)),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The song playing, or the next one: the event at a glance.
            if (cover == null)
              gradient
            else
              Image.network(cover, fit: BoxFit.cover, errorBuilder: (_, __, ___) => gradient),
            // The text stays readable on any picture.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.15),
                    Colors.black.withValues(alpha: cover == null ? 0.15 : 0.7),
                  ],
                ),
              ),
            ),
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: () async {
                  await context.push(eventPath(event.publicId));
                  onReturn?.call();
                },
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _PhaseChip(label: _label(phase)),
                          const Spacer(),
                          if (EntityBadges.fromFlags(
                                isOwner: event.viewerIsHost,
                                ownerSemanticLabel: 'You host it',
                                isPrivate: event.visibility == EventVisibility.private,
                                color: onCard,
                                iconSize: 20,
                              ) case final badges?)
                            badges,
                        ],
                      ),
                      const Spacer(),
                      Text(
                        event.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(color: onCard, fontWeight: FontWeight.bold),
                      ),
                      if (event.description case final description?)
                        Text(
                          description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(color: onCard),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _label(EventPhase phase) {
    final format = DateFormat('d MMM · HH:mm');
    return switch (phase) {
      // Same words as the Events list: "Live · until 23:00", "Paused".
      EventPhase.current => EventTile.when(event, now()),
      EventPhase.past => switch (event.endsAt ?? event.startsAt) {
          final at? => 'Ended ${DateFormat('d MMM').format(at)}',
          null => 'Ended',
        },
      EventPhase.upcoming => switch (event.startsAt) {
          final at? => 'Starts ${format.format(at)}',
          null => 'Upcoming',
        },
    };
  }
}

class _PhaseChip extends StatelessWidget {
  final String label;

  const _PhaseChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
    );
  }
}

/// The middle card when no event is happening.
class _NothingLiveCard extends StatelessWidget {
  const _NothingLiveCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Card(
        margin: EdgeInsets.zero,
        color: theme.colorScheme.surfaceContainerHighest,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.event_available, size: 36, color: theme.colorScheme.outline),
                const SizedBox(height: 8),
                Text('Nothing live right now', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Swipe for upcoming events',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
