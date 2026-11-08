import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/device/control_license.dart';
import 'package:app/core/models/device/user_device.dart';
import 'package:app/features/device/data/device_source.dart';

/// In-memory [DelegationApi] keeping the server's rules: one live licence per
/// friend, device and event (ConflictError), and revoking a licence that is
/// gone is NotFoundError. [failure] makes the next call throw. The host's
/// [devices], and [speakers] per event, as setSpeaker leaves them.
class FakeDelegationApi implements DelegationApi {
  final Map<String, List<ControlLicense>> byDevice = {};
  List<UserDevice> devices = const [];
  final Map<String, String> speakers = {};
  final List<String> calls = [];
  int _nextId = 1;
  AppError? failure;

  void _fail() {
    final error = failure;
    if (error != null) {
      failure = null;
      throw error;
    }
  }

  /// A licence made elsewhere; one with no [eventPublicId] stands for an
  /// old row from before every licence named an event.
  ControlLicense seed(String devicePublicId, String granteePublicId, {String? eventPublicId}) {
    final license = ControlLicense(
      id: _nextId++,
      granteePublicId: granteePublicId,
      eventPublicId: eventPublicId,
    );
    byDevice.putIfAbsent(devicePublicId, () => []).add(license);
    return license;
  }

  @override
  Future<List<UserDevice>> myDevices(String userPublicId) async {
    calls.add('devices $userPublicId');
    _fail();
    return List.of(devices);
  }

  @override
  Future<void> setSpeaker(String eventPublicId, String devicePublicId) async {
    calls.add('speaker $eventPublicId $devicePublicId');
    _fail();
    speakers[eventPublicId] = devicePublicId;
  }

  @override
  Future<List<ControlLicense>> licenses(String devicePublicId) async {
    calls.add('licenses $devicePublicId');
    _fail();
    return List.of(byDevice[devicePublicId] ?? const []);
  }

  @override
  Future<void> grant(String devicePublicId, String granteePublicId, String eventPublicId) async {
    calls.add('grant $devicePublicId $granteePublicId $eventPublicId');
    _fail();
    final existing = byDevice[devicePublicId] ?? const [];
    if (existing.any((l) => l.granteePublicId == granteePublicId && l.eventPublicId == eventPublicId)) {
      throw const ConflictError('already granted');
    }
    seed(devicePublicId, granteePublicId, eventPublicId: eventPublicId);
  }

  @override
  Future<void> revoke(String devicePublicId, int licenseId) async {
    calls.add('revoke $devicePublicId $licenseId');
    _fail();
    final licenses = byDevice[devicePublicId] ?? [];
    final before = licenses.length;
    licenses.removeWhere((l) => l.id == licenseId);
    if (licenses.length == before) {
      throw const NotFoundError('no such licence');
    }
  }
}
