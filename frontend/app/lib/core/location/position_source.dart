import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' as geo;

import 'package:app/core/errors/app_error.dart';

/// Where the phone is, in degrees.
typedef Position = ({double latitude, double longitude});

/// An event only counts votes from its venue, and the phone cannot say
/// where it is (PositionSource.current answered null).
class PositionUnavailableError extends DomainError {
  const PositionUnavailableError(super.message);
}

/// Where the phone is right now, for the events that only let people at
/// their venue vote (vote licence `location_time`). Null when it cannot be
/// known: no permission, location off, no fix in time, or nothing set.
abstract interface class PositionSource {
  Future<Position?> current();
}

/// The real phone's position (Android, iOS), asking for the permission the
/// first time it is needed.
class DevicePositionSource implements PositionSource {
  /// How long to wait for a fix before giving up: a vote must not hang.
  static const timeout = Duration(seconds: 10);

  @override
  Future<Position?> current() async {
    try {
      if (!await geo.Geolocator.isLocationServiceEnabled()) {
        return null;
      }
      var permission = await geo.Geolocator.checkPermission();
      if (permission == geo.LocationPermission.denied) {
        permission = await geo.Geolocator.requestPermission();
      }
      if (permission == geo.LocationPermission.denied ||
          permission == geo.LocationPermission.deniedForever) {
        return null;
      }
      final fix = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(timeLimit: timeout),
      );
      return (latitude: fix.latitude, longitude: fix.longitude);
    } catch (error) {
      debugPrint('Position: not available: $error');
      return null;
    }
  }
}

/// The demo phone's position (frontend/phone, the Linux build in Docker):
/// it has no GPS, so the position is the one picked with the 📍 button on
/// its page, written to [path] as "latitude,longitude". Missing, empty or
/// "off" is no position.
class FilePositionSource implements PositionSource {
  final String path;

  FilePositionSource(this.path);

  @override
  Future<Position?> current() async {
    try {
      return parse(await File(path).readAsString());
    } on FileSystemException {
      return null;
    }
  }

  /// "48.8566,2.3522" (spaces allowed); anything else is null.
  static Position? parse(String text) {
    final parts = text.trim().split(',');
    if (parts.length != 2) {
      return null;
    }
    final latitude = double.tryParse(parts[0].trim());
    final longitude = double.tryParse(parts[1].trim());
    if (latitude == null || longitude == null) {
      return null;
    }
    return (latitude: latitude, longitude: longitude);
  }
}

/// The file the demo phone's 📍 button writes (frontend/phone/entrypoint.sh).
const demoPositionFile = '/tmp/music-room/position';

/// The real position where the device has one, the demo file on Linux.
PositionSource platformPositionSource() =>
    !kIsWeb && Platform.isLinux ? FilePositionSource(demoPositionFile) : DevicePositionSource();
