// Tuple bookkeeping for uploaded images.
//
// Avatars and playlist covers are stored the same way -- an original plus a
// square thumbnail derived from it by image-service -- and replaced the same way,
// so the permission graph owes the same operations in both cases. That logic sat
// inline in four handlers before this file, which is three too many places to
// forget a delete in.
//
// The owner's public id is a parameter everywhere below, because images.owner_user_id
// is the internal BIGSERIAL and a tuple subject is always the public UUID. The
// caller has it: for an avatar it is the account being edited, for a cover the
// playlist's owner.
package media

import (
	"context"
	"errors"

	sqlc "example.com/music-app/db/sqlc"
	"example.com/music-app/internal/authz"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// NewImagePair is the tuple work owed by a freshly uploaded image and its
// thumbnail.
//
// Only the ORIGINAL carries the attachment. The thumbnail points at the original
// and inherits its audience through `can_view from original`, which is what keeps
// an image's audience in exactly one place however many variants exist. Attaching
// both would work today and silently stop working the first time a cover's
// audience changes and only one of the two tuples is updated.
//
// Two Changes, not one: two objects, and outbox ordering is per-object. A single
// row keyed on one of them would order correctly against neither.
func NewImagePair(original, thumb sqlc.Image, ownerPublicID string, attachment authz.ImageAttachment, origin string) []authz.Change {
	return []authz.Change{
		authz.NewImage(original.PublicID.String(), ownerPublicID, attachment, origin),
		authz.NewImage(
			thumb.PublicID.String(),
			ownerPublicID,
			authz.VariantAttachment(original.PublicID.String()),
			origin,
		),
	}
}

// DeleteImagePair removes the rows behind a replaced avatar or cover and reports
// both what to unlink from the graph and which files to unlink from the disk.
//
// imageID is the profile's or playlist's current pointer, which references the
// THUMBNAIL; the original is reached through its source_image_id. Both rows go,
// and so do both sets of tuples -- an undeleted playlist_cover_of would keep
// granting can_view on an image whose file no longer exists.
//
// The storage keys are returned rather than deleted here because the files must
// only go once the transaction has committed: a rollback that had already removed
// them would leave a perfectly valid row pointing at nothing.
//
// A missing row is not an error. The pointer can legitimately be stale, and
// failing a replacement because the thing being replaced is already gone would
// turn a no-op into an outage.
func DeleteImagePair(
	ctx context.Context,
	queries *sqlc.Queries,
	imageID pgtype.Int8,
	ownerPublicID string,
	attachment authz.ImageAttachment,
	origin string,
) (staleFiles []string, changes []authz.Change, err error) {
	if !imageID.Valid {
		return nil, nil, nil
	}

	thumb, err := queries.DeleteImage(ctx, imageID.Int64)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil, nil
		}
		return nil, nil, err
	}
	staleFiles = append(staleFiles, thumb.StorageKey)

	// images_variant_source_check makes a thumbnail without an original
	// impossible, so this branch only fires on data that predates the constraint
	// or was written around it. Nothing to inherit from, nothing else to delete.
	if !thumb.SourceImageID.Valid {
		return staleFiles, []authz.Change{authz.DeleteImage(
			thumb.PublicID.String(), ownerPublicID, authz.ImageAttachment{}, origin,
		)}, nil
	}

	original, err := queries.DeleteImage(ctx, thumb.SourceImageID.Int64)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, nil, err
	}
	if errors.Is(err, pgx.ErrNoRows) {
		// The thumbnail named an original that is gone. Its own tuple still has to
		// go, and the `original` relation it held can only be named with the id it
		// pointed at -- which is exactly what is missing. So this one tuple is
		// unremovable from here; it grants nothing, since inheriting from a
		// nonexistent object resolves to nothing, and it is logged as a known leak
		// rather than silently dropped.
		return staleFiles, []authz.Change{authz.DeleteImage(
			thumb.PublicID.String(), ownerPublicID, authz.ImageAttachment{}, origin,
		)}, nil
	}

	staleFiles = append(staleFiles, original.StorageKey)

	// Order within the slice is not significant -- these are two objects, and each
	// Change is applied on its own. Deletes-before-writes only matters inside one.
	return staleFiles, []authz.Change{
		authz.DeleteImage(original.PublicID.String(), ownerPublicID, attachment, origin),
		authz.DeleteImage(
			thumb.PublicID.String(),
			ownerPublicID,
			authz.VariantAttachment(original.PublicID.String()),
			origin,
		),
	}, nil
}
