import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:app/core/storage/secure_token_storage.dart';
import 'package:app/globals/app_constants.dart';

/// What this install of the app says about itself: on every call as headers
/// (core/network/client_metadata_interceptor.dart), and once per session
/// through RegisterDevice, which binds the session to a devices row on the
/// backend so its activity logs and playback commands (V.2.2) know the device
/// without being told again.
///
/// Subject V.6 asks every log to carry the platform, the device ("iPhone 6G,
/// iPad Air, Samsung Edge") and the application version: [platform], [model]
/// and [appVersion].
@immutable
class DeviceInfo {
  /// One of the backend's device_platform values: ios | android | web | desktop.
  final String platform;

  /// What the device list shows ("Where the music plays"): the name the
  /// system gives it, as Spotify Connect shows one. See [nameOf].
  final String name;

  /// The device for V.6, e.g. "iPhone 15 Pro" or "samsung SM-G998B". Empty
  /// when it could not be read ([fallback]).
  ///
  /// Linux, Windows and web expose no hardware model at all, so the OS (or the
  /// browser) stands in: on the Linux demo phone this reads "Ubuntu 24.04 LTS".
  final String model;

  final String appVersion;

  const DeviceInfo._(this.platform, this.name, this.model, this.appVersion);

  /// Everything but the model, which needs no asynchronous work: what the app
  /// runs with when [load] cannot read the device (no plugin under
  /// `flutter test`).
  factory DeviceInfo.fallback() {
    final (platform, label) = _platform();
    return DeviceInfo._(platform, '$label device', '', AppConstants.appVersion);
  }

  /// Reads the model from the OS. Await it before AppNetwork.connect(): the
  /// headers are fixed when the gRPC interceptors are built, and an
  /// interceptor cannot wait on a platform call.
  ///
  /// Never throws: a device that cannot be read still logs its platform and
  /// version, just without a model.
  static Future<DeviceInfo> load() async {
    final fallback = DeviceInfo.fallback();
    try {
      final info = await DeviceInfoPlugin().deviceInfo;
      final model = modelOf(info);
      final name = nameOf(
        platform: fallback.platform,
        model: model,
        hostname: kIsWeb ? '' : Platform.localHostname,
        fallback: fallback.name,
      );
      return DeviceInfo._(fallback.platform, name, model, fallback.appVersion);
    } catch (error) {
      debugPrint('Device model unavailable, logging without it: $error');
      return fallback;
    }
  }

  /// The [model] string for each platform's description of itself. Public for
  /// the tests, which build these objects by hand.
  ///
  /// iOS and macOS give a marketing name ("iPhone 15 Pro"), which reads like
  /// the subject's examples; the hardware identifier ("iPhone15,3") is kept as
  /// the fallback when the name is unknown (a model newer than the plugin).
  @visibleForTesting
  static String modelOf(BaseDeviceInfo info) => switch (info) {
        AndroidDeviceInfo(:final manufacturer, :final model) => '$manufacturer $model',
        IosDeviceInfo(:final modelName, :final utsname) =>
          modelName.isNotEmpty ? modelName : utsname.machine,
        MacOsDeviceInfo(:final modelName, :final model) =>
          modelName.isNotEmpty ? modelName : model,
        WindowsDeviceInfo(:final productName) => productName,
        LinuxDeviceInfo(:final prettyName) => prettyName,
        WebBrowserInfo(:final browserName, :final platform) =>
          '${browserName.name} on ${platform ?? 'unknown'}',
        _ => '',
      };

  /// The device's name, as its system gives it: a phone by its model
  /// ("Google Pixel 7", "iPhone 15 Pro": iOS no longer lets apps read the
  /// name its user picked), a computer by its name, its [hostname]
  /// ("greg-MS-7D99"; the demo phones are named in docker-compose.yaml).
  /// [fallback] ("Linux device") when the system says nothing.
  @visibleForTesting
  static String nameOf({
    required String platform,
    required String model,
    required String hostname,
    required String fallback,
  }) {
    final mobile = platform == 'ios' || platform == 'android';
    final name = mobile ? model : (hostname.isNotEmpty ? hostname : model);
    return name.trim().isEmpty ? fallback : name.trim();
  }

  static (String, String) _platform() {
    if (kIsWeb) {
      return ('web', 'Web');
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => ('ios', 'iOS'),
      TargetPlatform.android => ('android', 'Android'),
      TargetPlatform.macOS => ('desktop', 'macOS'),
      TargetPlatform.windows => ('desktop', 'Windows'),
      TargetPlatform.linux => ('desktop', 'Linux'),
      TargetPlatform.fuchsia => ('desktop', 'Fuchsia'),
    };
  }

  /// This install's stable id, generated the first time and kept in secure
  /// storage. RegisterDevice keys the device on it, so the same phone reuses
  /// one row (and keeps its control licences) across logins.
  static Future<String> identifier(SecureTokenStorage storage) async {
    final stored = await storage.getDeviceIdentifier();
    if (stored != null && stored.isNotEmpty) {
      return stored;
    }
    final created = const Uuid().v4();
    await storage.saveDeviceIdentifier(created);
    return created;
  }
}
