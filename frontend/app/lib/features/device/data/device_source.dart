import 'package:app/core/device/device_info.dart';
import 'package:app/core/mapping/delegation.mapping.dart';
import 'package:app/core/models/device/control_license.dart';
import 'package:app/core/models/device/user_device.dart';
import 'package:app/core/network/app_network.dart';
import 'package:app/core/sources/grpc_source.dart';
import 'package:app/features/device/data/commands/device_grpc_commands.dart';
import 'package:app/gen/music_room/v1/services/delegation_service.pbgrpc.dart';
import 'package:fixnum/fixnum.dart';

/// What the app needs from DelegationService's device half. An interface so
/// [DeviceStore] can be tested without a channel.
abstract interface class DeviceApi {
  /// Registers (or updates) this install on [userPublicId]'s account and binds
  /// the current session to it. Returns the device's ids: the public one names
  /// it in requests, the internal one is compared with an event's speaker.
  Future<({int id, String publicId})> registerDevice(
    String userPublicId,
    String identifier,
    DeviceInfo device,
  );
}

/// The licence half (subject V.2.2): which of the host's devices plays an
/// event's music, and who may control the music on it. Owner only, on the
/// server.
abstract interface class DelegationApi {
  /// [userPublicId]'s devices: the user's own only.
  Future<List<UserDevice>> myDevices(String userPublicId);

  /// Makes [devicePublicId], one of the host's devices, the one that plays
  /// [eventPublicId]'s music. The event's licences move to it.
  Future<void> setSpeaker(String eventPublicId, String devicePublicId);

  /// The live licences on [devicePublicId], each for one event.
  Future<List<ControlLicense>> licenses(String devicePublicId);

  /// Lets [granteePublicId], who must be a friend, control the music on
  /// [devicePublicId] during [eventPublicId]. ConflictError if they already
  /// can.
  Future<void> grant(String devicePublicId, String granteePublicId, String eventPublicId);

  /// NotFoundError if the licence was already revoked.
  Future<void> revoke(String devicePublicId, int licenseId);
}

/// Native gRPC implementation of [DeviceApi] and [DelegationApi]. Built with
/// the network's interceptors: RegisterDevice binds *the calling session*, so
/// it must carry the session token.
class DeviceGrpcSource extends GrpcSource<void, DelegationServiceClient>
    implements DeviceApi, DelegationApi {
  @override
  final DelegationServiceClient client;

  DeviceGrpcSource(super.channel, super.interceptors)
      : client = DelegationServiceClient(channel, interceptors: interceptors);

  static DeviceGrpcSource from(AppNetwork appNetwork) =>
      GrpcSource.create(appNetwork, DeviceGrpcSource.new);

  @override
  Future<({int id, String publicId})> registerDevice(
    String userPublicId,
    String identifier,
    DeviceInfo device,
  ) async {
    final response = await RegisterDeviceCommand(RegisterDeviceRequest(
      userPublicId: userPublicId,
      deviceIdentifier: identifier,
      name: device.name,
      platform: device.platform,
      model: device.model,
      appVersion: device.appVersion,
    ))(client);
    return (id: response.device.id.toInt(), publicId: response.device.publicId);
  }

  @override
  Future<List<UserDevice>> myDevices(String userPublicId) async {
    final response = await ListMyDevicesCommand(ListMyDevicesRequest(userPublicId: userPublicId))(client);
    return [for (final device in response.devices) device.toDomain()];
  }

  @override
  Future<void> setSpeaker(String eventPublicId, String devicePublicId) async {
    await SetEventSpeakerCommand(
      SetEventSpeakerRequest(eventPublicId: eventPublicId, devicePublicId: devicePublicId),
    )(client);
  }

  @override
  Future<List<ControlLicense>> licenses(String devicePublicId) async {
    final response = await ListDeviceControlLicensesCommand(
      ListDeviceControlLicensesRequest(devicePublicId: devicePublicId),
    )(client);
    return [for (final license in response.licenses) license.toDomain()];
  }

  @override
  Future<void> grant(String devicePublicId, String granteePublicId, String eventPublicId) async {
    await GrantDeviceControlCommand(GrantDeviceControlRequest(
      devicePublicId: devicePublicId,
      granteeUserPublicId: granteePublicId,
      eventPublicId: eventPublicId,
    ))(client);
  }

  @override
  Future<void> revoke(String devicePublicId, int licenseId) async {
    await RevokeDeviceControlCommand(RevokeDeviceControlRequest(
      devicePublicId: devicePublicId,
      licenseId: Int64(licenseId),
    ))(client);
  }
}
