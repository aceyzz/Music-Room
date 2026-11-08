import 'package:flutter/foundation.dart';

import 'package:app/core/device/device_info.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/device/data/device_source.dart';

/// This install's device on the backend, registered once per session.
///
/// Global, like CurrentUserStore: built in main.dart next to [SessionStore]
/// and follows it. Every new session (sign-in, or a session restored at
/// launch) calls RegisterDevice, which does two things on the backend: it
/// keeps the devices row current (app version after an update), and it binds
/// that session to the device, so the activity logs (V.6) of every later call
/// name it and a playback command is known to come from it.
///
/// Keyed on the session token, not the user: the binding is per session, and
/// signing out then in again as the same user is a new session to bind.
///
/// Best effort: a failed registration leaves [devicePublicId] null; the
/// session works, its calls just log without a device. The next launch
/// retries.
class DeviceStore {
  final DeviceApi _devices;
  final SessionStore _session;

  /// Where the stable id is read or created ([DeviceInfo.identifier]).
  final Future<String> Function() _identifier;

  /// What RegisterDevice records: the same values the headers carry.
  final DeviceInfo _device;

  /// The device's public id once registered: the device a host delegates
  /// control of, in the event player (docs/todo.md §4).
  final ValueNotifier<String?> devicePublicId = ValueNotifier(null);

  /// Its internal id, set with [devicePublicId]: the event player compares it
  /// with the event's speaker to know whether this app plays the sound.
  final ValueNotifier<int?> deviceId = ValueNotifier(null);

  /// The session registered or registering, so a session change that keeps
  /// the token (email verified) does not register again.
  String? _registeredFor;

  /// Set by [stop]: writing to a disposed notifier throws.
  bool _stopped = false;

  DeviceStore(this._devices, this._session, this._identifier, this._device);

  void start() {
    _session.state.addListener(_onSession);
    _onSession();
  }

  void stop() {
    _stopped = true;
    _session.state.removeListener(_onSession);
    devicePublicId.dispose();
    deviceId.dispose();
  }

  void _onSession() {
    final signedIn = switch (_session.state.value) {
      final SignedIn s => s,
      SignedOut() => null,
    };
    final token = signedIn?.session.token;
    if (token == _registeredFor) {
      return;
    }
    _registeredFor = token;
    devicePublicId.value = null;
    deviceId.value = null;
    if (signedIn != null) {
      _register(token!, signedIn.user.publicId);
    }
  }

  Future<void> _register(String token, String userPublicId) async {
    try {
      final identifier = await _identifier();
      final registered = await _devices.registerDevice(userPublicId, identifier, _device);
      // Dropped if the session changed meanwhile.
      if (!_stopped && _registeredFor == token) {
        deviceId.value = registered.id;
        devicePublicId.value = registered.publicId;
      }
    } catch (error) {
      // AppError from the call, or a secure-storage failure reading the id:
      // either way best effort, see the class comment.
      debugPrint('RegisterDevice failed, calls will log without a device: $error');
    }
  }
}
