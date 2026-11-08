package authz

// Tuple constructors for the image type.
//
// An image's audience is never its own: it is the audience of whatever it is
// attached to. The model says so directly —
//
//	can_view: owner or public or can_view from playlist_cover_of
//	          or can_view from event_cover_of or can_view from original
//
// — which means the only thing this file has to get right is the attachment. Get
// it wrong and a private playlist's cover is still reachable by its URL, because
// nothing else in the system knows the image was ever attached to anything.
//
// `original` is what lets a derived variant inherit its source's audience. The
// upload paths (UploadAvatar, SetPlaylistCover) create an original plus a resized
// thumbnail, and the thumbnail carries no attachment of its own — it points at
// the original and inherits from there. One place to change an image's audience,
// however many variants exist.

// ImageAttachment says what an image belongs to. Exactly one field is meaningful
// per image; the zero value is a private image visible only to its owner.
//
// Public is for avatars. That is a product decision taken deliberately: there is
// no avatar_visibility column in the data model and none is wanted — anyone may
// see a profile picture. It is not a shortcut for "I don't know the audience".
type ImageAttachment struct {
	Public           bool
	PlaylistPublicID string
	EventPublicID    string
	OriginalPublicID string
}

// AvatarAttachment is the audience of a profile picture.
func AvatarAttachment() ImageAttachment { return ImageAttachment{Public: true} }

// PlaylistCoverAttachment ties an image to the playlist it illustrates, so the
// cover of a private playlist is exactly as private as the playlist.
func PlaylistCoverAttachment(playlistPublicID string) ImageAttachment {
	return ImageAttachment{PlaylistPublicID: playlistPublicID}
}

// VariantAttachment is for a resized derivative: it inherits from its source and
// carries no audience of its own.
func VariantAttachment(originalPublicID string) ImageAttachment {
	return ImageAttachment{OriginalPublicID: originalPublicID}
}

func (a ImageAttachment) tuples(object string) []Tuple {
	var tuples []Tuple
	if a.Public {
		tuples = append(tuples, Tuple{User: Everyone, Relation: RelImagePublic, Object: object})
	}
	if a.PlaylistPublicID != "" {
		tuples = append(tuples, Tuple{
			User:     Object(TypePlaylist, a.PlaylistPublicID),
			Relation: RelPlaylistCover,
			Object:   object,
		})
	}
	if a.EventPublicID != "" {
		tuples = append(tuples, Tuple{
			User:     Object(TypeEvent, a.EventPublicID),
			Relation: RelEventCover,
			Object:   object,
		})
	}
	if a.OriginalPublicID != "" {
		tuples = append(tuples, Tuple{
			User:     Object(TypeImage, a.OriginalPublicID),
			Relation: RelOriginalImage,
			Object:   object,
		})
	}
	return tuples
}

// NewImage gives an image its owner and its attachment.
//
// origin is a parameter rather than a constant because the same two tuples are
// owed by an avatar upload and a playlist cover upload, and the outbox's origin
// column is the only record of which handler is responsible for a stuck row.
func NewImage(imagePublicID, ownerPublicID string, attachment ImageAttachment, origin string) Change {
	object := Object(TypeImage, imagePublicID)

	writes := []Tuple{{User: UserRef(ownerPublicID), Relation: RelImageOwner, Object: object}}
	writes = append(writes, attachment.tuples(object)...)

	return Change{ObjectKey: object, Origin: origin, Writes: writes}
}

// DeleteImage removes an image's tuples.
//
// Takes the same arguments as NewImage, for the same reason DeleteQueueEntry
// does: a tuple is deleted by naming it in full, and the graph is not queryable
// from here. The caller has the row.
//
// This is the one delete in the system with a concrete leak behind it. Replacing
// a playlist cover deletes the old images rows and their files, and an
// undeleted playlist_cover_of tuple would keep granting can_view on an image id
// that has been reissued to nobody — until gen_random_uuid() hands that id out
// again, which it will not, but the tuple is also holding back ordering on an
// object that no longer exists.
func DeleteImage(imagePublicID, ownerPublicID string, attachment ImageAttachment, origin string) Change {
	object := Object(TypeImage, imagePublicID)

	deletes := []Tuple{{User: UserRef(ownerPublicID), Relation: RelImageOwner, Object: object}}
	deletes = append(deletes, attachment.tuples(object)...)

	return Change{ObjectKey: object, Origin: origin, Deletes: deletes}
}
