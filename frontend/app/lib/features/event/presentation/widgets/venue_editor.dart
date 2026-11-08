import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'package:app/core/location/position_source.dart';
import 'package:app/core/models/event/event_settings.dart';
import 'package:app/features/event/presentation/widgets/venue_map.dart';

/// Where to start when an event has no venue yet: Paris, at the middle
/// radius.
const EventVenue defaultVenue = (latitude: 48.8566, longitude: 2.3522, radiusMeters: 500);

/// Where a place-and-time event counts votes from, in the form itself: drag
/// or tap the map, or type the coordinates, or take the phone's position; then pick
/// how far from it. Every change goes to [onChanged]: the venue, or null
/// while the typed coordinates are not a place.
///
/// The map is OpenStreetMap's tiles, which need the internet; the
/// coordinates work without them.
class VenueEditor extends StatefulWidget {
  /// The venue to start from. Read once: give the editor a new key to start
  /// it over.
  final EventVenue initial;
  final PositionSource positions;
  final ValueChanged<EventVenue?> onChanged;

  /// Off while a request runs.
  final bool enabled;

  /// Off in tests, which have no network for the tiles.
  final bool showMap;

  const VenueEditor({
    super.key,
    required this.initial,
    required this.positions,
    required this.onChanged,
    this.enabled = true,
    this.showMap = true,
  });

  @override
  State<VenueEditor> createState() => _VenueEditorState();
}

class _VenueEditorState extends State<VenueEditor> {
  final _map = MapController();
  late LatLng _point;
  late int _radius;
  late final _latitude = TextEditingController();
  late final _longitude = TextEditingController();
  bool _locating = false;

  /// The typed coordinates are not a place: the form waits for them.
  String? _error;

  /// "Use my position" found none: said, but the venue shown still counts.
  String? _notice;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _point = LatLng(initial.latitude, initial.longitude);
    _radius = initial.radiusMeters;
    _fillFields();
  }

  void _report() => widget.onChanged(_error != null
      ? null
      : (latitude: _point.latitude, longitude: _point.longitude, radiusMeters: _radius));

  @override
  void dispose() {
    _latitude.dispose();
    _longitude.dispose();
    super.dispose();
  }

  void _fillFields() {
    _latitude.text = _point.latitude.toStringAsFixed(5);
    _longitude.text = _point.longitude.toStringAsFixed(5);
  }

  /// From the map or the phone: the fields follow, and the map too.
  void _moveTo(LatLng point) {
    setState(() {
      _point = point;
      _error = null;
      _notice = null;
      _fillFields();
    });
    _report();
    if (widget.showMap) {
      _map.move(point, _map.camera.zoom);
    }
  }

  /// From dragging the map: the venue is its center, already under the pin.
  void _dragged(LatLng center) {
    setState(() {
      _point = center;
      _error = null;
      _notice = null;
      _fillFields();
    });
    _report();
  }

  /// From the fields: the map follows once both are valid coordinates.
  void _typed() {
    final latitude = double.tryParse(_latitude.text.trim());
    final longitude = double.tryParse(_longitude.text.trim());
    final valid =
        latitude != null && longitude != null && latitude.abs() <= 90 && longitude.abs() <= 180;
    setState(() => _error = valid ? null : 'Latitude -90 to 90, longitude -180 to 180.');
    if (valid) {
      _point = LatLng(latitude, longitude);
      if (widget.showMap) {
        _map.move(_point, _map.camera.zoom);
      }
    }
    _report();
  }

  Future<void> _useMyPosition() async {
    setState(() => _locating = true);
    final at = await widget.positions.current();
    if (!mounted) {
      return;
    }
    setState(() => _locating = false);
    if (at == null) {
      setState(() => _notice = 'Your position is not available.');
      return;
    }
    _moveTo(LatLng(at.latitude, at.longitude));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final enabled = widget.enabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Drag the map under the pin, type the coordinates, or use your position.',
            style: hint),
        const SizedBox(height: 8),
        if (widget.showMap) ...[
          VenueMap(
            point: _point,
            radiusMeters: _radius,
            height: 200,
            controller: _map,
            onTap: enabled ? _moveTo : null,
            onDragged: enabled ? _dragged : null,
            interactive: enabled,
          ),
          const SizedBox(height: 12),
        ],
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _latitude,
                enabled: enabled,
                decoration: const InputDecoration(labelText: 'Latitude', isDense: true),
                keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                onChanged: (_) => _typed(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _longitude,
                enabled: enabled,
                decoration: const InputDecoration(labelText: 'Longitude', isDense: true),
                keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                onChanged: (_) => _typed(),
              ),
            ),
          ],
        ),
        if ((_error ?? _notice) != null) ...[
          const SizedBox(height: 4),
          Text(_error ?? _notice!,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: !enabled || _locating ? null : _useMyPosition,
            icon: const Icon(Icons.my_location),
            label: Text(_locating ? 'Locating…' : 'Use my position'),
          ),
        ),
        Text('How far from it', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: [
            for (final r in venueRadii)
              ButtonSegment(value: r, label: Text(r < 1000 ? '$r m' : '${r ~/ 1000} km')),
          ],
          selected: {_radius},
          onSelectionChanged: enabled
              ? (picked) {
                  setState(() => _radius = picked.single);
                  _report();
                }
              : null,
        ),
      ],
    );
  }
}
