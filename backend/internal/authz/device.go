package authz

// Tuple constructors for the device type: its owner.
//
// A control licence is not in the graph: the device_control_licenses row is
// the permission, read by event/access.go canControlPlayback. A tuple is
// unique per (friend, device), and a friend may hold one licence per event on
// the same device.

// NewDevice gives a device its owner.
//
// One tuple, and every can_* on the device resolves through it — including
// can_grant_control, so without it the owner cannot delegate their own speaker.
func NewDevice(devicePublicID, ownerPublicID string) Change {
	object := Object(TypeDevice, devicePublicID)
	return Change{
		ObjectKey: object, Origin: OriginDeviceRegister,
		Writes: []Tuple{{User: UserRef(ownerPublicID), Relation: RelDeviceOwner, Object: object}},
	}
}
