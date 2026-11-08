import 'package:app/core/device/device_info.dart';
import 'package:app/features/device/data/device_source.dart';

/// In-memory [DeviceApi]: records each registration and answers with a fixed
/// device (id 1, public id device-1).
class FakeDeviceApi implements DeviceApi {
  final List<({String user, String identifier, DeviceInfo device})> registrations = [];
  Object? failure;

  @override
  Future<({int id, String publicId})> registerDevice(
    String userPublicId,
    String identifier,
    DeviceInfo device,
  ) async {
    registrations.add((user: userPublicId, identifier: identifier, device: device));
    final error = failure;
    if (error != null) {
      throw error;
    }
    return (id: 1, publicId: 'device-1');
  }
}
