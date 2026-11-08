package delegation

import (
	"context"
	"errors"

	sqlc "example.com/music-app/db/sqlc"
	"example.com/music-app/internal/authz"
	"example.com/music-app/internal/authz/outbox"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// Repository holds the delegation mutations.
//
// A device is in the graph (its owner, NewDevice). A licence is not: the
// device_control_licenses row is the permission, read by canControlPlayback
// (event/access.go), revoked by a timestamp and expired by expires_at. A tuple
// is unique per (friend, device), and a friend may hold one licence per event
// on the same device.
type Repository struct {
	db     outbox.DB
	outbox *outbox.Outbox
}

func NewRepository(db outbox.DB, ob *outbox.Outbox) *Repository {
	return &Repository{db: db, outbox: ob}
}

// RegisterDevice upserts the device, gives it its owner tuple, and binds the
// calling session to it.
//
// The app calls this on every launch with a stable device_identifier, so it
// runs constantly and almost always writes a tuple that already exists. That is
// free (Apply treats a duplicate as success) and it is the system's only
// self-repair path for a device whose tuple was lost.
//
// The session binding is what makes the device known to every later request:
// GetSessionByHash already reads user_sessions.device_id on each call, so the
// activity log (V.6) and playback commands get the device without a header or
// a lookup of their own. Same transaction as the upsert, so a session never
// points at a device row that was rolled back.
func (r *Repository) RegisterDevice(ctx context.Context, params sqlc.UpsertDeviceParams, sessionID int64) (sqlc.Device, error) {
	return outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) (sqlc.Device, []authz.Change, error) {
			queries := sqlc.New(tx)

			ownerPublicID, err := queries.GetUserPublicID(ctx, params.UserID)
			if err != nil {
				return sqlc.Device{}, nil, err
			}
			device, err := queries.UpsertDevice(ctx, params)
			if err != nil {
				return sqlc.Device{}, nil, err
			}
			if sessionID > 0 {
				err = queries.AttachSessionDevice(ctx, sqlc.AttachSessionDeviceParams{
					DeviceID: pgtype.Int8{Int64: device.ID, Valid: true}, SessionID: sessionID, UserID: params.UserID,
				})
				if err != nil {
					return sqlc.Device{}, nil, err
				}
			}

			change := authz.NewDevice(device.PublicID.String(), ownerPublicID.String())
			return device, []authz.Change{change}, nil
		})
}

// Grant inserts the licence.
func (r *Repository) Grant(ctx context.Context, params sqlc.GrantDeviceControlParams) (sqlc.DeviceControlLicense, error) {
	return sqlc.New(r.db).GrantDeviceControl(ctx, params)
}

// Revoke stamps revoked_at.
func (r *Repository) Revoke(ctx context.Context, params sqlc.RevokeDeviceControlParams) (sqlc.DeviceControlLicense, error) {
	return sqlc.New(r.db).RevokeDeviceControl(ctx, params)
}

// SetEventSpeaker makes deviceID the event's speaker, and moves the event's
// licences from the speaker it replaces: each one is revoked there and given
// again on deviceID, unless the friend already controls deviceID for this
// event. One transaction, so the speaker and its licences never disagree.
func (r *Repository) SetEventSpeaker(ctx context.Context, eventID, deviceID, hostID int64) error {
	return pgx.BeginFunc(ctx, r.db, func(tx pgx.Tx) error {
		queries := sqlc.New(tx)

		previous, err := queries.SetEventSpeaker(ctx, sqlc.SetEventSpeakerParams{
			EventID: eventID, DeviceID: pgtype.Int8{Int64: deviceID, Valid: true},
		})
		if err != nil || previous == 0 || previous == deviceID {
			return err
		}
		licenses, err := queries.ListEventLicensesOnDevice(ctx, sqlc.ListEventLicensesOnDeviceParams{
			DeviceID: previous, EventID: pgtype.Int8{Int64: eventID, Valid: true},
		})
		if err != nil {
			return err
		}
		for _, license := range licenses {
			_, err := queries.RevokeDeviceControl(ctx, sqlc.RevokeDeviceControlParams{
				ID: license.ID, DeviceID: previous, RevokerUserID: license.GrantedByID,
			})
			if err != nil {
				return err
			}

			_, err = queries.ResolveDeviceControlLicense(ctx, sqlc.ResolveDeviceControlLicenseParams{
				DeviceID: deviceID, GranteeUserID: license.GranteeUserID,
				EventID: pgtype.Int8{Int64: eventID, Valid: true},
			})
			if err == nil {
				continue // already in control of the new speaker.
			}
			if !errors.Is(err, pgx.ErrNoRows) {
				return err
			}
			_, err = queries.GrantDeviceControl(ctx, sqlc.GrantDeviceControlParams{
				DeviceID: deviceID, GranteeUserID: license.GranteeUserID,
				GrantedByID: hostID, EventID: eventID,
			})
			if err != nil {
				return err
			}
		}
		return nil
	})
}
