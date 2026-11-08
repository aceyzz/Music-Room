package authz

// Tuple constructors for the playlist type.
//
// Three independent columns on the playlists row drive them, and the model keeps
// them independent on purpose:
//
//   - owner_id        -> owner
//   - visibility      -> the public wildcard
//   - edit_license    -> the open_edit wildcard
//
// plus one relation per playlist_members row, named by its role.
//
// can_edit_songs is `... or (can_view and open_edit)`, never bare open_edit, so a
// private playlist with edit_license = 'everyone' is not world-writable. That
// conjunction only holds if both wildcards are transcribed faithfully -- which is
// why visibility and license each get their own constructor rather than being
// folded into one "settings" change that could skip one of them.

// playlistRoles is the mutually exclusive set: a playlist_members row has exactly
// one role, so at most one of these may exist per (playlist, user).
var playlistRoles = map[MemberRole]Relation{
	RoleOwner:  RelPlaylistOwner,
	RoleAdmin:  RelPlaylistAdmin,
	RoleEditor: RelPlaylistEditor,
	RoleViewer: RelPlaylistViewer,
}

var playlistRoleRelations = []Relation{
	RelPlaylistOwner, RelPlaylistAdmin, RelPlaylistEditor, RelPlaylistViewer,
}

// NewPlaylist is the tuple set a playlist needs from the moment it exists.
//
// Deletes are omitted: nothing exists yet for this object. Creation is the one
// case allowed to skip them -- every subsequent change must carry them.
//
// The owner tuple is written here AND by PlaylistMember when CreatePlaylist
// inserts the owner's playlist_members row. Writing it twice is harmless (Apply
// is idempotent), but it is not redundant: playlists.owner_id is the authority
// for ownership and the members row is a convenience, so the graph must not
// depend on which of the two a future refactor keeps.
func NewPlaylist(playlistPublicID, ownerPublicID string, visibility Visibility, license EditLicense) Change {
	object := Object(TypePlaylist, playlistPublicID)

	change := Change{ObjectKey: object, Origin: OriginPlaylistCreate}
	change.Writes = append(change.Writes, Tuple{
		User:     UserRef(ownerPublicID),
		Relation: RelPlaylistOwner,
		Object:   object,
	})
	if visibility == VisibilityPublic {
		change.Writes = append(change.Writes, Tuple{
			User: Everyone, Relation: RelPlaylistPublic, Object: object,
		})
	}
	if license == EditLicenseEveryone {
		change.Writes = append(change.Writes, Tuple{
			User: Everyone, Relation: RelOpenEdit, Object: object,
		})
	}
	return change
}

// PlaylistVisibility makes the public wildcard match the column.
//
// A two-state column, so this is a write-or-delete rather than a swap -- but the
// delete is still unconditional on the private branch, for the reason on
// exclusive(): the caller's belief about the current tuple is not evidence.
func PlaylistVisibility(playlistPublicID string, visibility Visibility) Change {
	object := Object(TypePlaylist, playlistPublicID)
	tuple := Tuple{User: Everyone, Relation: RelPlaylistPublic, Object: object}

	change := Change{ObjectKey: object, Origin: OriginPlaylistVisibility}
	if visibility == VisibilityPublic {
		change.Writes = []Tuple{tuple}
	} else {
		change.Deletes = []Tuple{tuple}
	}
	return change
}

// PlaylistEditLicense makes the open_edit wildcard match the column.
//
// Mirrors PlaylistVisibility exactly, on the other independent wildcard: a
// two-state column, write-or-delete rather than a swap, delete unconditional
// on the invited_only branch for the same reason (the caller's belief about
// the current tuple is not evidence).
func PlaylistEditLicense(playlistPublicID string, license EditLicense) Change {
	object := Object(TypePlaylist, playlistPublicID)
	tuple := Tuple{User: Everyone, Relation: RelOpenEdit, Object: object}

	change := Change{ObjectKey: object, Origin: OriginPlaylistLicense}
	if license == EditLicenseEveryone {
		change.Writes = []Tuple{tuple}
	} else {
		change.Deletes = []Tuple{tuple}
	}
	return change
}

// PlaylistMember transcribes one playlist_members row.
//
// Used for an insert and for a role change alike, because they produce the same
// Change: write the new role, delete the other three. That is what makes a role
// change safe without reading the old value -- and a demotion from admin to
// viewer that only wrote `viewer` would leave `admin` standing, which the model
// resolves as still-an-admin.
//
// An unrecognised role writes nothing and deletes all four. Failing closed is the
// only safe reading of a value this package does not understand.
func PlaylistMember(playlistPublicID, userPublicID string, role MemberRole) Change {
	object := Object(TypePlaylist, playlistPublicID)
	writes, deletes := exclusiveFor(object, UserRef(userPublicID), playlistRoleRelations, playlistRoles[role], nil)
	return Change{
		ObjectKey: object, Origin: OriginPlaylistMember,
		Writes: writes, Deletes: deletes,
	}
}
