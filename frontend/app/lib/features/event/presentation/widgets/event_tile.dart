import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:app/core/models/event/event_settings.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/widgets/entity_badges.dart';
import 'package:app/globals/app_router.dart';

/// One row of the Events tab: a calendar leaf with the start day, the name,
/// and when it runs ("Until 23:00", "20:00 – 23:00 · in 2 h"). A star marks
/// one the user hosts, a lock a private one. Tapping opens the event's screen ([eventPath]), and
/// [onReturn] runs once back: what happened there (a pause, the last song)
/// changes what the row says.
class EventTile extends StatelessWidget {
  final EventSummary event;

  /// Decides which screen a tap opens, and highlights a live event.
  final DateTime now;
  final VoidCallback? onReturn;

  const EventTile({super.key, required this.event, required this.now, this.onReturn});

  /// When [event] runs, in the user's time zone:
  ///  - "Sat 15 Oct · 20:00 – 23:00" within a day;
  ///  - "15 Oct 20:00 – 16 Oct 02:00" across midnight;
  ///  - with the year ("Fri 15 Jan 2027 · …", "31 Dec 2026 21:00 – 1 Jan 2027
  ///    03:00") on a date that is not in [now]'s year, past or future.
  /// Every event has times (CreateEvent requires them): empty otherwise.
  static String dates(EventSummary event, DateTime now) {
    final starts = event.startsAt;
    final ends = event.endsAt;
    if (starts == null) {
      return '';
    }
    String withYear(String pattern, DateTime date) =>
        DateFormat(date.year == now.year ? pattern : '$pattern y').format(date);
    final time = DateFormat('HH:mm');
    if (ends == null) {
      return '${withYear('EEE d MMM', starts)} · ${time.format(starts)}';
    }
    if (DateUtils.isSameDay(starts, ends)) {
      return '${withYear('EEE d MMM', starts)} · ${time.format(starts)} – ${time.format(ends)}';
    }
    return '${withYear('d MMM', starts)} ${time.format(starts)} – '
        '${withYear('d MMM', ends)} ${time.format(ends)}';
  }

  /// When an event that has not started runs, for its row: the start day is
  /// on the leaf beside it, so --
  ///  - "20:00 – 23:00" when it ends the same day;
  ///  - "23:00 – 11 Nov 02:00" when it ends another day, that day too (and
  ///    its year, when not the start's);
  ///  - with " · in 20 min" / " · in 3 h" when it starts within a day.
  static String slot(EventSummary event, DateTime now) {
    final starts = event.startsAt;
    final ends = event.endsAt;
    if (starts == null) {
      return '';
    }
    final time = DateFormat('HH:mm');
    final end = switch (ends) {
      null => null,
      _ when DateUtils.isSameDay(starts, ends) => time.format(ends),
      _ when ends.year == starts.year => DateFormat('d MMM HH:mm').format(ends),
      _ => DateFormat('d MMM y HH:mm').format(ends),
    };
    final hours = end == null ? time.format(starts) : '${time.format(starts)} – $end';
    final left = starts.difference(now);
    if (left <= Duration.zero || left >= const Duration(days: 1)) {
      return hours;
    }
    final soon = left.inHours == 0 ? '${left.inMinutes.clamp(1, 59)} min' : '${left.inHours} h';
    return '$hours · in $soon';
  }

  /// What the subtitle says: for an event running now, until when -- the
  /// time alone when it ends within a day, the day too for a festival;
  /// otherwise when it runs ([slot]). No playing / paused / no music: the
  /// event's page says what plays.
  static String when(EventSummary event, DateTime now) {
    if (event.phaseAt(now) != EventPhase.current) {
      return slot(event, now);
    }
    final ends = event.endsAt;
    if (ends == null) {
      return 'Now';
    }
    final within = ends.difference(now) < const Duration(days: 1);
    final pattern = within
        ? 'HH:mm'
        : ends.year == now.year
            ? 'd MMM HH:mm'
            : 'd MMM y HH:mm';
    return 'Until ${DateFormat(pattern).format(ends)}';
  }

  @override
  Widget build(BuildContext context) {
    final private = event.visibility == EventVisibility.private;
    return ListTile(
      leading: _DateLeaf(start: event.startsAt, now: now),
      title: Text(event.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(when(event, now), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: EntityBadges.fromFlags(
        isOwner: event.viewerIsHost,
        ownerSemanticLabel: 'You host it',
        isPrivate: private,
      ),
      onTap: () async {
        await context.push(eventPath(event.publicId));
        onReturn?.call();
      },
    );
  }
}

/// A 56 px calendar leaf: the start's month over its day, in soft colours (a
/// list of them stays light; the subtitle says what is live). The month says
/// the year too ("JAN '27") when it is not this one. An event icon when there
/// is no start.
class _DateLeaf extends StatelessWidget {
  final DateTime? start;
  final DateTime now;

  const _DateLeaf({required this.start, required this.now});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final background = scheme.surfaceContainerHighest;
    final foreground = scheme.onSurfaceVariant;
    final start = this.start;
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(8)),
      child: start == null
          ? Icon(Icons.event, color: foreground)
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  DateFormat(start.year == now.year ? 'MMM' : "MMM ''yy")
                      .format(start)
                      .toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(color: foreground),
                ),
                Text(
                  '${start.day}',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(color: foreground, fontWeight: FontWeight.bold, height: 1.1),
                ),
              ],
            ),
    );
  }
}
