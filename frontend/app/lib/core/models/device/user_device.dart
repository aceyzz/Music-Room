/// One of the user's devices (DeviceDTO): what the host picks the event's
/// speaker among.
class UserDevice {
  /// Internal id: what an event's playback names its speaker by.
  final int id;

  /// What requests name it by.
  final String publicId;
  final String name;

  /// ios | android | web | desktop
  final String platform;

  const UserDevice({required this.id, required this.publicId, required this.name, required this.platform});

  @override
  bool operator ==(Object other) =>
      other is UserDevice &&
      other.id == id &&
      other.publicId == publicId &&
      other.name == name &&
      other.platform == platform;

  @override
  int get hashCode => Object.hash(id, publicId, name, platform);
}
