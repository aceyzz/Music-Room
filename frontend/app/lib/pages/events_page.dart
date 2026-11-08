import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/widgets/async_list_view.dart';
import 'package:app/core/widgets/filter_pills.dart';
import 'package:app/core/widgets/tab_action_button.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/event/data/event_source.dart';
import 'package:app/features/event/presentation/stores/my_events_store.dart';
import 'package:app/features/event/presentation/widgets/create_event_sheet.dart';
import 'package:app/features/event/presentation/widgets/event_tile.dart';
import 'package:app/globals/app_router.dart';
import 'package:app/pages/main_app_bar.dart';
import 'package:app/pages/main_shell.dart';

/// The Events tab: two pills (Current, Upcoming), a button to create an
/// event, and the list under the selected pill. Ended events are not shown.
///
/// The list holds every event the user may see: theirs, the ones they were
/// invited to, and public ones (GetMusicEvents, ListObjects(can_view)).
class EventsPage extends StatefulWidget {
  /// Where "now" is, which sorts events into the pills. A parameter for
  /// tests.
  final DateTime Function() now;

  const EventsPage({super.key, this.now = DateTime.now});

  @override
  State<EventsPage> createState() => _EventsPageState();
}

class _EventsPageState extends State<EventsPage> with ReloadWhenShown<EventsPage> {
  // ---------------------------------------------------------------------------
  // State Variables
  // ---------------------------------------------------------------------------

  late final MyEventsStore _store;
  var _filter = EventFilter.current;
  final _refresh = GlobalKey<RefreshIndicatorState>();

  // ---------------------------------------------------------------------------
  // Lifecycle & Navigation
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _store = MyEventsStore(context.read<EventApi>(), context.currentUserId)..start();
    watchTab();
  }

  @override
  int get tabIndex => 2;

  @override
  void onShownAgain() => _store.reload();

  @override
  void dispose() {
    _store.stop();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  /// Opens the new event's screen once created.
  Future<void> _create() async {
    final created = await showCreateEventSheet(context, _store.create, now: widget.now);
    if (created != null && mounted) {
      context.push(eventPath(created.publicId));
    }
  }

  // ---------------------------------------------------------------------------
  // Computed Views (Subviews)
  // ---------------------------------------------------------------------------

  /// Segmented filter pills switching between Current and Upcoming events.
  Widget get _filterPills => FilterPills(
        values: EventFilter.values,
        selected: _filter,
        label: (filter) => filter.label,
        onTap: (filter) => setState(() => _filter = filter),
      );

  /// Primary action button invoking the modal to create a new event.
  Widget get _createButton => TabActionButton(
        label: 'Create event',
        icon: Icons.add,
        onPressed: _create,
      );

  /// Dynamic asynchronous list of events filtered by the current selection.
  Widget get _eventsList => ValueListenableBuilder(
        valueListenable: _store.events,
        builder: (context, state, _) {
          final now = widget.now();
          final events = state.data;
          return AsyncListView<EventSummary>(
            refreshKey: _refresh,
            state: state,
            items: events == null ? null : _filter.pick(events, now),
            emptyMessage: switch (_filter) {
              EventFilter.current => 'Nothing is happening right now.',
              EventFilter.upcoming => 'No upcoming events. Create one!',
            },
            onRefresh: _store.reload,
            itemBuilder: (context, event, _) =>
                EventTile(event: event, now: now, onReturn: _store.reload),
          );
        },
      );

  // ---------------------------------------------------------------------------
  // Main Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: MainAppBar(onRefresh: () => _refresh.currentState?.show()),
      body: Column(
        children: [
          _filterPills,
          _createButton,
          Expanded(child: _eventsList),
        ],
      ),
    );
  }
}
