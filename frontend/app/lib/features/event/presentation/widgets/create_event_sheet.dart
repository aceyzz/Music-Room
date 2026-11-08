import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/location/position_source.dart';
import 'package:app/core/models/event/event_settings.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/loading_button.dart';
import 'package:app/features/event/presentation/widgets/venue_editor.dart';

/// What creates the event: MyEventsStore.create, passed in so the sheet does
/// not depend on the store.
typedef CreateEvent = Future<EventSummary> Function({
  required String name,
  required String description,
  required EventVisibility visibility,
  required VoteLicense voteLicense,
  required DateTime startsAt,
  required DateTime endsAt,
  EventVenue? venue,
});

/// Opens the "new event" form from the bottom of the screen. Returns the
/// created event, or null when the user closed the form. [now] sets the
/// default times; a parameter for tests.
Future<EventSummary?> showCreateEventSheet(
  BuildContext context,
  CreateEvent create, {
  DateTime Function() now = DateTime.now,
  PositionSource? positions,
  bool showMap = true,
}) {
  return showModalBottomSheet<EventSummary>(
    context: context,
    // Grows above the keyboard instead of being hidden by it, and lets the
    // form, taller than a playlist's, use the screen's height.
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) =>
        CreateEventSheet(create: create, now: now, positions: positions, showMap: showMap),
  );
}

class CreateEventSheet extends StatefulWidget {
  final CreateEvent create;
  final DateTime Function() now;

  /// The app's own limits: the server sets none, but these have to fit a row
  /// and an info page.
  static const maxNameLength = 100;
  static const maxDescriptionLength = 500;

  /// How long a new event lasts unless the user picks an end.
  static const defaultLength = Duration(hours: 3);

  /// Where the phone is, for the venue's "Use my position". Defaults to
  /// [platformPositionSource]; a parameter for tests.
  final PositionSource? positions;

  /// Off in tests, which have no network for the map's tiles.
  final bool showMap;

  const CreateEventSheet({
    super.key,
    required this.create,
    this.now = DateTime.now,
    this.positions,
    this.showMap = true,
  });

  @override
  State<CreateEventSheet> createState() => _CreateEventSheetState();
}

class _CreateEventSheetState extends State<CreateEventSheet> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _description = TextEditingController();

  // The server's defaults.
  EventVisibility _visibility = EventVisibility.public;
  VoteChoice _vote = VoteChoice.everyone;

  /// Where votes count from, under [VoteChoice.placeAndTime].
  EventVenue? _venue;

  /// Asked once, kept for the page's life: the editor's "Use my position".
  late final PositionSource _positions = widget.positions ?? platformPositionSource();

  late DateTime _start;
  late DateTime _end;

  bool _busy = false;

  /// Why the times are refused, checked on Create.
  String? _timesError;
  String? _error;

  @override
  void initState() {
    super.initState();
    // The next full hour: a round time, and not already started.
    final now = widget.now();
    _start = DateTime(now.year, now.month, now.day, now.hour + 1);
    _end = _start.add(CreateEventSheet.defaultLength);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  /// Moving the start moves the end with it, keeping the length: picking
  /// another day should not leave the end on the old one.
  void _setStart(DateTime start) {
    final length = _end.isAfter(_start) ? _end.difference(_start) : CreateEventSheet.defaultLength;
    setState(() {
      _start = start;
      _end = start.add(length);
      _timesError = null;
    });
  }

  void _setEnd(DateTime end) {
    setState(() {
      _end = end;
      _timesError = null;
    });
  }

  Future<void> _pickDate(DateTime current, ValueChanged<DateTime> set) async {
    final today = DateUtils.dateOnly(widget.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: current.isBefore(today) ? today : current,
      firstDate: today,
      lastDate: today.add(const Duration(days: 2 * 365)),
    );
    if (picked != null) {
      set(DateTime(picked.year, picked.month, picked.day, current.hour, current.minute));
    }
  }

  Future<void> _pickTime(DateTime current, ValueChanged<DateTime> set) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (picked != null) {
      set(DateTime(current.year, current.month, current.day, picked.hour, picked.minute));
    }
  }

  /// The server checks the same two rules; checking here first says which
  /// field is wrong. A start in the past is fine: the event starts now.
  String? _checkTimes() {
    if (!_end.isAfter(_start)) {
      return 'The event must end after it starts.';
    }
    if (!_end.isAfter(widget.now())) {
      return 'The event must end in the future.';
    }
    return null;
  }

  Future<void> _submit() async {
    final timesError = _checkTimes();
    final valid = _formKey.currentState!.validate();
    setState(() => _timesError = timesError);
    if (!valid || timesError != null) {
      return;
    }
    if (_vote == VoteChoice.placeAndTime && _venue == null) {
      setState(() => _error = 'Fix the coordinates of the venue.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final created = await widget.create(
        name: _name.text.trim(),
        description: _description.text.trim(),
        visibility: _visibility,
        voteLicense: _vote == VoteChoice.invited ? VoteLicense.invitedOnly : VoteLicense.everyone,
        startsAt: _start,
        endsAt: _end,
        // The window is the times above (voteWindowFor).
        venue: _vote == VoteChoice.placeAndTime ? _venue : null,
      );
      if (mounted) {
        Navigator.of(context).pop(created);
      }
    } on AppError catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = switch (error) {
            NetworkError() => 'Cannot reach the server. Check your connection.',
            InvalidInputError(:final message) => message,
            _ => 'The event could not be created.',
          };
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final errorStyle = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error);
    final error = _error;
    final timesError = _timesError;
    return PopScope(
      canPop: !_busy, // no closing while the request runs
      child: Padding(
        // Keeps the form above the on-screen keyboard.
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: AppDimens.sheetPadding,
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('New event', style: theme.textTheme.titleLarge),
                const SizedBox(height: AppDimens.spacingM),
                TextFormField(
                  controller: _name,
                  enabled: !_busy,
                  autofocus: true,
                  maxLength: CreateEventSheet.maxNameLength,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? 'Give your event a name.' : null,
                ),
                const SizedBox(height: AppDimens.spacingXS),
                TextFormField(
                  controller: _description,
                  enabled: !_busy,
                  maxLength: CreateEventSheet.maxDescriptionLength,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Description (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: AppDimens.spacingXS),
                _WhenRow(
                  label: 'Starts',
                  keyPrefix: 'starts',
                  at: _start,
                  onDate: _busy ? null : () => _pickDate(_start, _setStart),
                  onTime: _busy ? null : () => _pickTime(_start, _setStart),
                ),
                const SizedBox(height: AppDimens.spacingXS),
                _WhenRow(
                  label: 'Ends',
                  keyPrefix: 'ends',
                  at: _end,
                  onDate: _busy ? null : () => _pickDate(_end, _setEnd),
                  onTime: _busy ? null : () => _pickTime(_end, _setEnd),
                ),
                if (timesError != null) ...[
                  const SizedBox(height: AppDimens.spacingXS),
                  Text(timesError, style: errorStyle),
                ],
                const SizedBox(height: AppDimens.spacingM),
                Text('Who can see it', style: theme.textTheme.titleSmall),
                const SizedBox(height: AppDimens.spacingXS),
                SegmentedButton<EventVisibility>(
                  segments: [
                    for (final v in EventVisibility.values)
                      ButtonSegment(value: v, label: _Fit(v.label)),
                  ],
                  selected: {_visibility},
                  onSelectionChanged:
                      _busy ? null : (picked) => setState(() => _visibility = picked.single),
                ),
                const SizedBox(height: AppDimens.spacingXXS),
                Text(_visibility.description, style: hint),
                const SizedBox(height: AppDimens.spacingM),
                Text('Who can vote', style: theme.textTheme.titleSmall),
                const SizedBox(height: AppDimens.spacingXS),
                SegmentedButton<VoteChoice>(
                  // Three labels and a check on a phone: less padding, and a label that
                  // shrinks rather than wrap (_Fit).
                  style: SegmentedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: AppDimens.spacingXXS),
                  ),
                  segments: [
                    for (final v in VoteChoice.values)
                      ButtonSegment(value: v, label: _Fit(v.label)),
                  ],
                  selected: {_vote},
                  onSelectionChanged: _busy
                      ? null
                      : (picked) => setState(() {
                            _vote = picked.single;
                            _error = null;
                            if (_vote == VoteChoice.placeAndTime) {
                              _venue ??= defaultVenue;
                            }
                          }),
                ),
                const SizedBox(height: AppDimens.spacingXXS),
                Text(
                  switch (_vote) {
                    VoteChoice.everyone => VoteLicense.everyone.description,
                    VoteChoice.invited => VoteLicense.invitedOnly.description,
                    VoteChoice.placeAndTime => placeAndTimeText(_venue, _start, _end),
                  },
                  style: hint,
                ),
                // Where votes count from, right here.
                if (_vote == VoteChoice.placeAndTime) ...[
                  const SizedBox(height: AppDimens.spacingS),
                  VenueEditor(
                    initial: _venue ?? defaultVenue,
                    positions: _positions,
                    showMap: widget.showMap,
                    enabled: !_busy,
                    onChanged: (venue) => setState(() => _venue = venue),
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: AppDimens.spacingM),
                  Text(error, style: errorStyle),
                ],
                const SizedBox(height: AppDimens.spacingL),
                LoadingButton(
                  label: 'Create',
                  busy: _busy,
                  onPressed: _submit,
                  height: AppDimens.buttonHeightStandard,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Starts  [Sat 15 Oct]  [21:00]": a label and two buttons that open the
/// date and time pickers. Keys `<keyPrefix>-date` and `<keyPrefix>-time`.
class _WhenRow extends StatelessWidget {
  final String label;
  final String keyPrefix;
  final DateTime at;
  final VoidCallback? onDate;
  final VoidCallback? onTime;

  /// Smaller than the app's buttons: two rows of them, under the name.
  static final _compact = OutlinedButton.styleFrom(
    minimumSize: const Size(0, 36),
    padding: const EdgeInsets.symmetric(horizontal: AppDimens.spacingS),
    visualDensity: VisualDensity.compact,
    textStyle: const TextStyle(fontSize: 13),
  );

  const _WhenRow({
    required this.label,
    required this.keyPrefix,
    required this.at,
    required this.onDate,
    required this.onTime,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(label, style: Theme.of(context).textTheme.titleSmall),
        ),
        Expanded(
          child: OutlinedButton.icon(
            key: Key('$keyPrefix-date'),
            style: _compact,
            onPressed: onDate,
            icon: const Icon(Icons.calendar_today, size: AppDimens.iconS),
            label: Text(DateFormat('EEE d MMM y').format(at)),
          ),
        ),
        const SizedBox(width: AppDimens.spacingXS),
        OutlinedButton.icon(
          key: Key('$keyPrefix-time'),
          style: _compact,
          onPressed: onTime,
          icon: const Icon(Icons.schedule, size: AppDimens.iconS),
          label: Text(DateFormat('HH:mm').format(at)),
        ),
      ],
    );
  }
}

/// A segment label on one line, a little smaller when it does not fit.
class _Fit extends StatelessWidget {
  final String text;

  const _Fit(this.text);

  @override
  Widget build(BuildContext context) =>
      FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1));
}
