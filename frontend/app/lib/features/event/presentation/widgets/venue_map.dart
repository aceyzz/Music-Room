import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// A place-and-time event's venue on an OpenStreetMap map: a pin, and the
/// circle votes count from. The venue picker moves it ([controller], [onTap]
/// with the point, [onDragged] with the center while the map is dragged:
/// the pin then stays in the middle and the map slides under it); the
/// settings page shows it still, and a tap there means "change the place"
/// ([interactive] off: no panning inside a scrolling page).
///
/// The tiles need the internet.
class VenueMap extends StatelessWidget {
  static const double _pinSize = 36;

  /// The place icon's tip is 2/24 of its size above the bottom of its box.
  static const double _pinTipGap = _pinSize * 2 / 24;

  final LatLng point;
  final int radiusMeters;
  final double height;
  final MapController? controller;
  final ValueChanged<LatLng>? onTap;
  final ValueChanged<LatLng>? onDragged;
  final bool interactive;

  const VenueMap({
    super.key,
    required this.point,
    required this.radiusMeters,
    this.height = 220,
    this.controller,
    this.onTap,
    this.onDragged,
    this.interactive = true,
  });

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    final onTap = this.onTap;
    final onDragged = this.onDragged;
    final pin = Icon(Icons.place, color: color, size: _pinSize);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: height,
        child: FlutterMap(
          mapController: controller,
          options: MapOptions(
            initialCenter: point,
            initialZoom: 14,
            interactionOptions: InteractionOptions(
              flags: interactive ? InteractiveFlag.all : InteractiveFlag.none,
            ),
            onTap: onTap == null ? null : (_, tapped) => onTap(tapped),
            // Only the user's gestures: the picker's own moves already know
            // where they go.
            onPositionChanged: onDragged == null
                ? null
                : (camera, hasGesture) {
                    if (hasGesture) {
                      onDragged(camera.center);
                    }
                  },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              // Who is asking, as OpenStreetMap's tile policy wants: it blocks
              // the template's com.example.app.
              userAgentPackageName: 'music-room.app',
            ),
            // Dragged: the circle sits on the camera's center, read in the
            // same frame as the tiles, not on [point], which comes back a
            // frame later.
            Builder(
              builder: (context) => CircleLayer(circles: [
                CircleMarker(
                  point: onDragged == null ? point : MapCamera.of(context).center,
                  radius: radiusMeters.toDouble(),
                  useRadiusInMeter: true,
                  color: color.withValues(alpha: 0.15),
                  borderColor: color,
                  borderStrokeWidth: 2,
                ),
              ]),
            ),
            // Dragged: the pin is drawn over the map, in the middle, so it
            // never lags behind the tiles.
            if (onDragged == null)
              MarkerLayer(markers: [
                // In the marker's 30-point box, the 36-point icon overflows
                // by the tip's gap: the tip lands on the point.
                Marker(point: point, alignment: Alignment.topCenter, child: pin),
              ])
            else
              IgnorePointer(
                child: Center(
                  child: Transform.translate(
                    offset: const Offset(0, -_pinSize / 2 + _pinTipGap),
                    child: pin,
                  ),
                ),
              ),
            // OpenStreetMap's tile policy asks for it.
            const SimpleAttributionWidget(source: Text('OpenStreetMap contributors')),
          ],
        ),
      ),
    );
  }
}
