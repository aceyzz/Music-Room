package playlist

import (
	"context"
	"encoding/json"

	sqlc "example.com/music-app/db/sqlc"
	"example.com/music-app/internal/authz"
	"example.com/music-app/internal/authz/outbox"
	"example.com/music-app/internal/media"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// Repository holds the playlist mutations that owe permission tuples.
//
// Only those. The service keeps its reads, its DTO mapping and the mutations the
// graph does not care about -- adding and removing songs, most of all, which is
// governed by playlist#can_edit_songs and produces no tuple of its own (the song
// catalogue is world-readable and playlist_songs rows are not permission
// objects). Splitting on "does this owe a tuple" rather than "is this SQL" keeps
// the transaction and the outbox in the same place without rewriting a service
// that works.
//
// Every method here goes through outbox.InTx, which is what guarantees the tuple
// intent commits with the row it describes.
type Repository struct {
	db     outbox.DB
	outbox *outbox.Outbox
}

func NewRepository(db outbox.DB, ob *outbox.Outbox) *Repository {
	return &Repository{db: db, outbox: ob}
}

// CreateParams is the playlist to insert.
type CreateParams struct {
	OwnerID     int64
	Name        string
	Description pgtype.Text
	Visibility  sqlc.ResourceVisibility
	EditLicense sqlc.EditLicense
}

// Create inserts the playlist, its owner's membership row, and the tuples both
// imply.
//
// The owner's public id is fetched rather than passed in: the request names the
// owner by internal id, and a tuple subject is always the public UUID. Doing the
// lookup inside the transaction also makes it the existence check -- no rows means
// no such account, which is the answer UserExists used to give in a second query.
//
// Two tuple-relevant columns beyond ownership, and they are independent on
// purpose: visibility drives `public`, edit_license drives `open_edit`, and
// can_edit_songs is `... or (can_view and open_edit)` precisely so that a private
// playlist with edit_license = 'everyone' is not world-writable.
func (r *Repository) Create(ctx context.Context, params CreateParams) (sqlc.Playlist, error) {
	return outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) (sqlc.Playlist, []authz.Change, error) {
			queries := sqlc.New(tx)
			ownerPublicID, err := queries.GetUserPublicID(ctx, params.OwnerID)
			if err != nil {
				return sqlc.Playlist{}, nil, err
			}

			created, err := queries.CreatePlaylist(ctx, sqlc.CreatePlaylistParams{
				OwnerID:     params.OwnerID,
				Name:        params.Name,
				Description: params.Description,
				Visibility:  params.Visibility,
				EditLicense: params.EditLicense,
			})
			if err != nil {
				return sqlc.Playlist{}, nil, err
			}

			if err := queries.AddPlaylistOwner(ctx, sqlc.AddPlaylistOwnerParams{
				PlaylistID: created.ID,
				UserID:     params.OwnerID,
			}); err != nil {
				return sqlc.Playlist{}, nil, err
			}

			change := authz.NewPlaylist(
				created.PublicID.String(),
				ownerPublicID.String(),
				authz.Visibility(created.Visibility),
				authz.EditLicense(created.EditLicense),
			)
			return created, []authz.Change{change}, nil
		})
}

// SetVisibility flips the playlist between public and private.
//
// This mutation had no transaction at all before: it was a single UPDATE on the
// pool. It needs one now, and not as a formality -- visibility is the column that
// decides whether `can_view` answers yes for every user in the system, so a
// committed row whose tuple never landed is a private playlist the graph still
// calls public.
//
// The Change is built from the RETURNED row, not from the requested value. They
// agree, and deriving from the row is the rule (a default or a trigger must not
// be able to disagree with the graph) -- it costs nothing to follow it here.
func (r *Repository) SetVisibility(ctx context.Context, playlistID int64, visibility sqlc.ResourceVisibility) (sqlc.Playlist, error) {
	return outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) (sqlc.Playlist, []authz.Change, error) {
			queries := sqlc.New(tx)
			updated, err := queries.SetPlaylistVisibility(ctx, sqlc.SetPlaylistVisibilityParams{
				ID:         playlistID,
				Visibility: visibility,
			})
			if err != nil {
				return sqlc.Playlist{}, nil, err
			}
			// No actor: SetPlaylistVisibility has no CallerPublicIDField
			// (policy.go) -- any caller holding can_change_visibility may
			// act, and the interceptor never learns who they were.
			if err := appendOp(ctx, queries, playlistID, updated.Revision, 0,
				sqlc.PlaylistOpTypeVisibilityChange, map[string]any{"visibility": string(updated.Visibility)}); err != nil {
				return sqlc.Playlist{}, nil, err
			}

			change := authz.PlaylistVisibility(
				updated.PublicID.String(),
				authz.Visibility(updated.Visibility),
			)
			return updated, []authz.Change{change}, nil
		})
}

// SetEditLicense flips the playlist between everyone and invited_only.
//
// Mirrors SetVisibility exactly: same reasoning (the tuple wildcard must
// agree with the column the moment the row commits), same Change-from-the-
// returned-row rule.
func (r *Repository) SetEditLicense(ctx context.Context, playlistID int64, license sqlc.EditLicense) (sqlc.Playlist, error) {
	return outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) (sqlc.Playlist, []authz.Change, error) {
			queries := sqlc.New(tx)
			updated, err := queries.SetPlaylistEditLicense(ctx, sqlc.SetPlaylistEditLicenseParams{
				ID:          playlistID,
				EditLicense: license,
			})
			if err != nil {
				return sqlc.Playlist{}, nil, err
			}
			// No actor here either -- same reasoning as SetVisibility.
			if err := appendOp(ctx, queries, playlistID, updated.Revision, 0,
				sqlc.PlaylistOpTypeLicenseChange, map[string]any{"edit_license": string(updated.EditLicense)}); err != nil {
				return sqlc.Playlist{}, nil, err
			}

			change := authz.PlaylistEditLicense(
				updated.PublicID.String(),
				authz.EditLicense(updated.EditLicense),
			)
			return updated, []authz.Change{change}, nil
		})
}

// appendOp journals one mutation into playlist_ops, at the revision the
// mutation's own UPDATE already bumped (SetPlaylistVisibility/
// SetPlaylistEditLicense/TransferPlaylistOwnership fold `revision =
// revision + 1` into their own statement, see db/query/playlists.sql; a
// mutation on another table calls BumpPlaylistRevision separately first). Same three-step shape documented at the top of that
// file, just inside outbox.InTx here instead of the service's raw
// beginTx/commitTx -- these mutations already own tuples, so the
// transaction was already open.
//
// actorID is 0 (-> NULL) wherever the RPC has no CallerPublicIDField
// (policy.go) and so never learns who called it -- see each call site.
func appendOp(ctx context.Context, queries *sqlc.Queries, playlistID, revision, actorID int64, opType sqlc.PlaylistOpType, payload map[string]any) error {
	encoded, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	_, err = queries.AppendPlaylistOp(ctx, sqlc.AppendPlaylistOpParams{
		PlaylistID: playlistID, Revision: revision,
		ActorID: pgtype.Int8{Int64: actorID, Valid: actorID > 0},
		OpType:  opType, Payload: encoded,
	})
	return err
}

// AddMember adds an invited user to the playlist as an editor.
//
// AddPlaylistMember is ON CONFLICT DO NOTHING, so re-inviting someone is a no-op
// in Postgres -- and the tuple is written anyway. That is deliberate: a repeat
// invitation is the cheapest opportunity to repair a membership whose tuple was
// lost, and PlaylistMember is idempotent. Skipping the write when the row already
// existed would make the drift permanent.
//
// The role is hard-coded to editor because AddPlaylistMember hard-codes it. When a
// role-change RPC appears, PlaylistMember already handles it: it writes the new
// role and deletes the other three in one Change, which is what stops a demotion
// from leaving the old, higher role standing.
func (r *Repository) AddMember(ctx context.Context, playlistID, userID int64) error {
	_, err := outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) (struct{}, []authz.Change, error) {
			queries := sqlc.New(tx)
			playlist, err := queries.GetPlaylistByID(ctx, playlistID)
			if err != nil {
				return struct{}{}, nil, err
			}
			memberPublicID, err := queries.GetUserPublicID(ctx, userID)
			if err != nil {
				return struct{}{}, nil, err
			}

			if err := queries.AddPlaylistMember(ctx, sqlc.AddPlaylistMemberParams{
				PlaylistID: playlistID,
				UserID:     userID,
			}); err != nil {
				return struct{}{}, nil, err
			}

			change := authz.PlaylistMember(
				playlist.PublicID.String(),
				memberPublicID.String(),
				authz.RoleEditor,
			)
			return struct{}{}, []authz.Change{change}, nil
		})
	return err
}

// TransferOwnership hands the playlist to an existing member and demotes the
// current owner to admin (product decision: they keep day-to-day
// management, just not can_delete/can_transfer_ownership).
//
// newOwnerID must already have a playlist_members row -- PromotePlaylistMemberToOwner
// affects 0 rows otherwise, which surfaces as pgx.ErrNoRows here exactly like
// a :one query finding nothing, so the caller's existing databaseError
// mapping (-> NotFound) needs no special case for it.
//
// Two Changes, not one: PlaylistMember already handles a role swap
// generically (write the new role, delete the other three -- see
// authz/playlist.go), so reusing it for both users is the same tuple
// constructor AddMember uses, not new logic.
func (r *Repository) TransferOwnership(ctx context.Context, playlistID, currentOwnerID, newOwnerID int64) (sqlc.Playlist, error) {
	return outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) (sqlc.Playlist, []authz.Change, error) {
			queries := sqlc.New(tx)

			rows, err := queries.PromotePlaylistMemberToOwner(ctx, sqlc.PromotePlaylistMemberToOwnerParams{
				PlaylistID: playlistID, UserID: newOwnerID,
			})
			if err != nil {
				return sqlc.Playlist{}, nil, err
			}
			if rows == 0 {
				return sqlc.Playlist{}, nil, pgx.ErrNoRows
			}

			if err := queries.DemotePlaylistOwnerToAdmin(ctx, sqlc.DemotePlaylistOwnerToAdminParams{
				PlaylistID: playlistID, UserID: currentOwnerID,
			}); err != nil {
				return sqlc.Playlist{}, nil, err
			}

			updated, err := queries.TransferPlaylistOwnership(ctx, sqlc.TransferPlaylistOwnershipParams{
				PlaylistID: playlistID, NewOwnerID: newOwnerID, CurrentOwnerID: currentOwnerID,
			})
			if err != nil {
				return sqlc.Playlist{}, nil, err
			}

			newOwnerPublicID, err := queries.GetUserPublicID(ctx, newOwnerID)
			if err != nil {
				return sqlc.Playlist{}, nil, err
			}
			currentOwnerPublicID, err := queries.GetUserPublicID(ctx, currentOwnerID)
			if err != nil {
				return sqlc.Playlist{}, nil, err
			}

			// Actor is known here, unlike SetVisibility/SetEditLicense
			// above: TransferPlaylistOwnership DOES have a
			// CallerPublicIDField (current_owner_user_public_id), enforced
			// by the interceptor before this runs.
			if err := appendOp(ctx, queries, playlistID, updated.Revision, currentOwnerID,
				sqlc.PlaylistOpTypeOwnershipTransfer,
				map[string]any{"new_owner_user_id": newOwnerID, "previous_owner_user_id": currentOwnerID}); err != nil {
				return sqlc.Playlist{}, nil, err
			}

			changes := []authz.Change{
				authz.PlaylistMember(updated.PublicID.String(), newOwnerPublicID.String(), authz.RoleOwner),
				authz.PlaylistMember(updated.PublicID.String(), currentOwnerPublicID.String(), authz.RoleAdmin),
			}
			return updated, changes, nil
		})
}

// CoverUpload is everything SetCover needs that the service had to compute
// first: the two files are already resized and written to disk by then.
//
// Keeping the image-service round trip and the file writes OUT of the transaction
// is not incidental. They are slow and they talk to another process; holding a
// Postgres transaction open across them would put a network call inside a row
// lock.
type CoverUpload struct {
	PlaylistID  int64
	OwnerID     int64
	ContentType string

	OriginalKey  string
	OriginalSize int
	ThumbKey     string
	ThumbSize    int
	ThumbPixels  int

	// PreviousCoverImageID is the playlist's current cover, to be replaced.
	// Invalid when it had none.
	PreviousCoverImageID pgtype.Int8
}

// SetCover writes the two image rows, points the playlist at the thumbnail, and
// removes whatever cover was there before.
//
// Returns the storage keys of the replaced files, which the caller deletes only
// after this returns -- the transaction has committed by then, so there is no
// rollback that could leave the playlist pointing at a file that no longer
// exists.
//
// The cover's audience is the playlist's: `can_view from playlist_cover_of`. That
// single tuple is the only thing making a private playlist's cover private, since
// an image is otherwise reachable by anyone who knows its key.
func (r *Repository) SetCover(ctx context.Context, upload CoverUpload) (sqlc.Playlist, []string, error) {
	type result struct {
		playlist   sqlc.Playlist
		staleFiles []string
	}

	out, err := outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) (result, []authz.Change, error) {
			queries := sqlc.New(tx)
			ownerPublicID, err := queries.GetUserPublicID(ctx, upload.OwnerID)
			if err != nil {
				return result{}, nil, err
			}
			playlist, err := queries.GetPlaylistByID(ctx, upload.PlaylistID)
			if err != nil {
				return result{}, nil, err
			}
			attachment := authz.PlaylistCoverAttachment(playlist.PublicID.String())

			original, err := queries.CreateImage(ctx, sqlc.CreateImageParams{
				OwnerUserID: upload.OwnerID,
				StorageKey:  upload.OriginalKey,
				ContentType: upload.ContentType,
				ByteSize:    pgtype.Int4{Int32: int32(upload.OriginalSize), Valid: true},
				Variant:     "original",
			})
			if err != nil {
				return result{}, nil, err
			}
			thumb, err := queries.CreateImage(ctx, sqlc.CreateImageParams{
				OwnerUserID:   upload.OwnerID,
				StorageKey:    upload.ThumbKey,
				ContentType:   "image/png",
				Width:         pgtype.Int4{Int32: int32(upload.ThumbPixels), Valid: true},
				Height:        pgtype.Int4{Int32: int32(upload.ThumbPixels), Valid: true},
				ByteSize:      pgtype.Int4{Int32: int32(upload.ThumbSize), Valid: true},
				Variant:       "thumb",
				SourceImageID: pgtype.Int8{Int64: original.ID, Valid: true},
			})
			if err != nil {
				return result{}, nil, err
			}

			updated, err := queries.SetPlaylistCover(ctx, sqlc.SetPlaylistCoverParams{
				PlaylistID:   upload.PlaylistID,
				CoverImageID: pgtype.Int8{Int64: thumb.ID, Valid: true},
			})
			if err != nil {
				return result{}, nil, err
			}

			changes := media.NewImagePair(original, thumb, ownerPublicID.String(), attachment, authz.OriginPlaylistCover)

			staleFiles, staleChanges, err := media.DeleteImagePair(
				ctx, queries, upload.PreviousCoverImageID,
				ownerPublicID.String(), attachment, authz.OriginPlaylistCover,
			)
			if err != nil {
				return result{}, nil, err
			}
			changes = append(changes, staleChanges...)

			return result{playlist: updated, staleFiles: staleFiles}, changes, nil
		})

	return out.playlist, out.staleFiles, err
}

// ClearCover removes the playlist's cover, if it had one.
//
// coverImageID comes from the caller's earlier read rather than being looked up
// again. That read is also the permission check, so it has already happened; a
// second one would only widen the window between deciding and acting.
func (r *Repository) ClearCover(ctx context.Context, playlistID, ownerID int64, coverImageID pgtype.Int8) ([]string, error) {
	return outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) ([]string, []authz.Change, error) {
			queries := sqlc.New(tx)
			if !coverImageID.Valid {
				return nil, nil, nil
			}

			ownerPublicID, err := queries.GetUserPublicID(ctx, ownerID)
			if err != nil {
				return nil, nil, err
			}
			playlist, err := queries.GetPlaylistByID(ctx, playlistID)
			if err != nil {
				return nil, nil, err
			}

			if err := queries.ClearPlaylistCover(ctx, playlistID); err != nil {
				return nil, nil, err
			}

			staleFiles, changes, err := media.DeleteImagePair(
				ctx, queries, coverImageID, ownerPublicID.String(),
				authz.PlaylistCoverAttachment(playlist.PublicID.String()),
				authz.OriginPlaylistCoverClear,
			)
			if err != nil {
				return nil, nil, err
			}
			return staleFiles, changes, nil
		})
}
