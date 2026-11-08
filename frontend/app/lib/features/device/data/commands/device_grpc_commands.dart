import 'package:app/core/commands/categories/grpc_commands.dart';
import 'package:app/gen/music_room/v1/services/delegation_service.pbgrpc.dart';

// One command per DelegationService RPC the app calls.

class RegisterDeviceCommand extends RpcCallCommand<RegisterDeviceRequest,
    RegisterDeviceResponse, DelegationServiceClient> {
  const RegisterDeviceCommand(super.request);

  @override
  Future<RegisterDeviceResponse> execute(
    DelegationServiceClient client,
    RegisterDeviceRequest request,
  ) =>
      client.registerDevice(request);
}

class ListDeviceControlLicensesCommand extends RpcCallCommand<ListDeviceControlLicensesRequest,
    ListDeviceControlLicensesResponse, DelegationServiceClient> {
  const ListDeviceControlLicensesCommand(super.request);

  @override
  Future<ListDeviceControlLicensesResponse> execute(
    DelegationServiceClient client,
    ListDeviceControlLicensesRequest request,
  ) =>
      client.listDeviceControlLicenses(request);
}

class GrantDeviceControlCommand extends RpcCallCommand<GrantDeviceControlRequest,
    GrantDeviceControlResponse, DelegationServiceClient> {
  const GrantDeviceControlCommand(super.request);

  @override
  Future<GrantDeviceControlResponse> execute(
    DelegationServiceClient client,
    GrantDeviceControlRequest request,
  ) =>
      client.grantDeviceControl(request);
}

class RevokeDeviceControlCommand extends RpcCallCommand<RevokeDeviceControlRequest,
    RevokeDeviceControlResponse, DelegationServiceClient> {
  const RevokeDeviceControlCommand(super.request);

  @override
  Future<RevokeDeviceControlResponse> execute(
    DelegationServiceClient client,
    RevokeDeviceControlRequest request,
  ) =>
      client.revokeDeviceControl(request);
}

class ListMyDevicesCommand
    extends RpcCallCommand<ListMyDevicesRequest, ListMyDevicesResponse, DelegationServiceClient> {
  const ListMyDevicesCommand(super.request);

  @override
  Future<ListMyDevicesResponse> execute(DelegationServiceClient client, ListMyDevicesRequest request) =>
      client.listMyDevices(request);
}

class SetEventSpeakerCommand
    extends RpcCallCommand<SetEventSpeakerRequest, SetEventSpeakerResponse, DelegationServiceClient> {
  const SetEventSpeakerCommand(super.request);

  @override
  Future<SetEventSpeakerResponse> execute(DelegationServiceClient client, SetEventSpeakerRequest request) =>
      client.setEventSpeaker(request);
}
