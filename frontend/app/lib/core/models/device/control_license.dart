import 'package:flutter/foundation.dart';

/// A friend's licence to control the music on one of the user's devices
/// (subject V.2.2: specific to each device), for one event.
@immutable
class ControlLicense {
  /// What RevokeDeviceControl takes. Internal id: only sent back, never shown.
  final int id;
  final String granteePublicId;

  /// The event it is for; null only on a licence from before every licence
  /// named one (the server revoked those).
  final String? eventPublicId;

  const ControlLicense({required this.id, required this.granteePublicId, this.eventPublicId});

  @override
  bool operator ==(Object other) =>
      other is ControlLicense &&
      other.id == id &&
      other.granteePublicId == granteePublicId &&
      other.eventPublicId == eventPublicId;

  @override
  int get hashCode => Object.hash(id, granteePublicId, eventPublicId);
}
