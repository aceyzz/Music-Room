import 'package:app/core/models/device/control_license.dart';
import 'package:app/core/models/device/user_device.dart';
import 'package:app/gen/music_room/v1/dto/delegation.pb.dart';

extension DeviceControlLicenseDTOMapping on DeviceControlLicenseDTO {
  ControlLicense toDomain() => ControlLicense(
        id: id.toInt(),
        granteePublicId: granteeUserPublicId,
        eventPublicId: eventPublicId.isEmpty ? null : eventPublicId,
      );
}

extension DeviceDTOMapping on DeviceDTO {
  UserDevice toDomain() => UserDevice(id: id.toInt(), publicId: publicId, name: name, platform: platform);
}
