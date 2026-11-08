package interceptor

import (
	"context"
	"errors"
	"fmt"

	sqlc "example.com/music-app/db/sqlc"
	"example.com/music-app/internal/authz"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// ErrUnknownObject means no usable row carries that public id: it never
// existed, it was soft-deleted, or the account is gone.
var ErrUnknownObject = errors.New("unknown object")

// Resolver translates a public UUID into the internal id the handlers use.
//
// One indexed lookup per object named in a request. That cost is the price of
// an API whose request bodies speak internal ids while the graph speaks public
// UUIDs, and it buys the invariant that matters: the handler's id is derived
// from the id that was checked, so the two cannot drift apart. The cost is an
// indexed single-row read, and it is not where the load test saturates
// (OpenFGA is, docs/load-testing.md).
//
// Not cached, on purpose. The mapping is immutable (an id never changes hands)
// so a cache would be safe for it, but each query also answers "is this still
// there" (deleted_at), and a cache would be a second place for that to be
// wrong.
type Resolver struct {
	queries *sqlc.Queries
}

func NewResolver(db sqlc.DBTX) *Resolver {
	return &Resolver{queries: sqlc.New(db)}
}

// Resolve returns the internal id behind publicID, which must already be
// canonical (authz.NormalizePublicID).
func (r *Resolver) Resolve(ctx context.Context, objectType authz.ObjectType, publicID string) (int64, error) {
	var uuid pgtype.UUID
	if err := uuid.Scan(publicID); err != nil {
		return 0, ErrUnknownObject
	}

	var (
		id  int64
		err error
	)
	switch objectType {
	case authz.TypeUser:
		id, err = r.queries.GetUserIDByPublicID(ctx, uuid)
	case authz.TypePlaylist:
		id, err = r.queries.GetPlaylistIDByPublicID(ctx, uuid)
	case authz.TypeEvent:
		id, err = r.queries.GetEventIDByPublicID(ctx, uuid)
	case authz.TypeQueueEntry:
		id, err = r.queries.GetQueueEntryIDByPublicID(ctx, uuid)
	case authz.TypeDevice:
		id, err = r.queries.GetDeviceIDByPublicID(ctx, uuid)
	default:
		// authz.TypeImage has no request that names one: images are reached
		// through the resource they are attached to. A policy entry that named
		// one would land here rather than resolving to something wrong.
		return 0, fmt.Errorf("no resolution query for object type %q", objectType)
	}

	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, ErrUnknownObject
		}
		return 0, err
	}
	return id, nil
}
