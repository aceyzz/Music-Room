package event

import (
	"context"
	"log"
	"time"

	sqlc "example.com/music-app/db/sqlc"
	"example.com/music-app/internal/authz"
	"example.com/music-app/internal/authz/outbox"
	"github.com/jackc/pgx/v5"
)

// Repository holds the event mutations that owe permission tuples: creation,
// the vote licence, invitations, and queue entries.
//
// Not here, and deliberately: voting and playback. A vote is gated by
// event#can_vote, which resolves from the licence flag this file writes, and
// produces no tuple of its own. Playback state is the same -- events.status is a
// residual Go check (docs/permissions.md), never a tuple.
type Repository struct {
	db     outbox.DB
	outbox *outbox.Outbox
}

func NewRepository(db outbox.DB, ob *outbox.Outbox) *Repository {
	return &Repository{db: db, outbox: ob}
}

// CreateParams is the event to insert, plus the queue it starts with.
//
// SourceSongIDs is resolved by the caller BEFORE the transaction opens. Reading
// the source playlist inside it bought nothing -- the seeded queue is a snapshot
// either way -- and it kept a transaction open across work that does not need it.
type CreateParams struct {
	Insert        sqlc.CreateEventSimpleParams
	SourceSongIDs []int64
}

// Create inserts the event, its host's membership row, its playback state, and
// any seeded queue entries — with the tuples all of that implies.
//
// The tuple count is not fixed: one Change for the event, plus one per seeded
// song. Seeding from a 200-track playlist enqueues 201 outbox rows in one
// transaction, and that is the honest cost of every queue entry being its own
// permission object. They deliver in order and independently; a failure on one
// does not hold back the others, because they are different objects.
func (r *Repository) Create(ctx context.Context, params CreateParams) (sqlc.Event, error) {
	return outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) (sqlc.Event, []authz.Change, error) {
			queries := sqlc.New(tx)

			hostPublicID, err := queries.GetUserPublicID(ctx, params.Insert.HostID)
			if err != nil {
				return sqlc.Event{}, nil, err
			}

			created, err := queries.CreateEventSimple(ctx, params.Insert)
			if err != nil {
				return sqlc.Event{}, nil, err
			}
			if err := queries.AddEventOwner(ctx, sqlc.AddEventOwnerParams{
				EventID: created.ID, UserID: params.Insert.HostID,
			}); err != nil {
				return sqlc.Event{}, nil, err
			}
			if err := queries.CreateEventPlaybackState(ctx, created.ID); err != nil {
				return sqlc.Event{}, nil, err
			}

			eventPublicID := created.PublicID.String()
			changes := []authz.Change{authz.NewEvent(
				eventPublicID,
				hostPublicID.String(),
				authz.Visibility(created.Visibility),
				authz.VoteLicense(created.VoteLicense),
				voteWindowOf(created),
			)}

			for _, songID := range params.SourceSongIDs {
				entry, err := queries.SuggestSongToQueue(ctx, sqlc.SuggestSongToQueueParams{
					EventID: created.ID, SongID: songID, SuggestedByID: params.Insert.HostID,
				})
				if err != nil {
					return sqlc.Event{}, nil, err
				}
				changes = append(changes, authz.NewQueueEntry(
					entry.PublicID.String(), eventPublicID, hostPublicID.String(),
				))
			}

			return created, changes, nil
		})
}

// SetVisibility makes the event public or private, and its public wildcard
// follow, in the same transaction.
func (r *Repository) SetVisibility(ctx context.Context, eventID int64, visibility sqlc.ResourceVisibility) (sqlc.Event, error) {
	return outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) (sqlc.Event, []authz.Change, error) {
			updated, err := sqlc.New(tx).SetEventVisibility(ctx, sqlc.SetEventVisibilityParams{
				ID: eventID, Visibility: visibility,
			})
			if err != nil {
				return sqlc.Event{}, nil, err
			}
			change := authz.EventVisibility(updated.PublicID.String(), authz.Visibility(updated.Visibility))
			return updated, []authz.Change{change}, nil
		})
}

// SetVoteLicense swaps the licence and the venue/window columns that go with it.
func (r *Repository) SetVoteLicense(ctx context.Context, params sqlc.SetEventVoteLicenseParams) (sqlc.Event, error) {
	return outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) (sqlc.Event, []authz.Change, error) {
			updated, err := sqlc.New(tx).SetEventVoteLicense(ctx, params)
			if err != nil {
				return sqlc.Event{}, nil, err
			}

			change := authz.EventVoteLicense(
				updated.PublicID.String(),
				authz.VoteLicense(updated.VoteLicense),
				voteWindowOf(updated),
			)
			return updated, []authz.Change{change}, nil
		})
}

// AddMember adds an invited user to the event as a viewer.
//
// Viewer, because AddEventMember hard-codes that role. It is enough for the
// invited_only licence: can_vote_invited is `member and invited_vote`, and a
// viewer is a member.
func (r *Repository) AddMember(ctx context.Context, eventID, userID int64) error {
	_, err := outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) (struct{}, []authz.Change, error) {
			queries := sqlc.New(tx)

			event, err := queries.GetEventByID(ctx, eventID)
			if err != nil {
				return struct{}{}, nil, err
			}
			memberPublicID, err := queries.GetUserPublicID(ctx, userID)
			if err != nil {
				return struct{}{}, nil, err
			}

			if err := queries.AddEventMember(ctx, sqlc.AddEventMemberParams{
				EventID: eventID, UserID: userID,
			}); err != nil {
				return struct{}{}, nil, err
			}

			change := authz.EventMember(
				event.PublicID.String(), memberPublicID.String(), authz.RoleViewer,
			)
			return struct{}{}, []authz.Change{change}, nil
		})
	return err
}

// SuggestSong adds one song to an event's queue.
//
// suggesterID may be 0: SuggestSongToQueue NULLIFs it, and NewQueueEntry then
// writes only the `parent` tuple. The entry stays viewable and votable through
// its event and simply has nobody holding can_remove through `suggester`, which
// is the correct outcome for an anonymous suggestion rather than a gap.
func (r *Repository) SuggestSong(ctx context.Context, eventID, songID, suggesterID int64) (sqlc.EventQueueEntry, error) {
	return outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) (sqlc.EventQueueEntry, []authz.Change, error) {
			queries := sqlc.New(tx)

			event, err := queries.GetEventByID(ctx, eventID)
			if err != nil {
				return sqlc.EventQueueEntry{}, nil, err
			}

			var suggesterPublicID string
			if suggesterID > 0 {
				id, err := queries.GetUserPublicID(ctx, suggesterID)
				if err != nil {
					return sqlc.EventQueueEntry{}, nil, err
				}
				suggesterPublicID = id.String()
			}

			entry, err := queries.SuggestSongToQueue(ctx, sqlc.SuggestSongToQueueParams{
				EventID: eventID, SongID: songID, SuggestedByID: suggesterID,
			})
			if err != nil {
				return sqlc.EventQueueEntry{}, nil, err
			}

			change := authz.NewQueueEntry(
				entry.PublicID.String(), event.PublicID.String(), suggesterPublicID,
			)
			return entry, []authz.Change{change}, nil
		})
}

// voteWindowOf reads the condition's parameters off the event row.
//
// From the row and never from the request, which is the rule (a default or a
// trigger must not be able to disagree with the graph) and here also the only
// correct source: SetEventVoteLicense nulls the venue and window columns when the
// licence moves away from location_time, because events_location_time_license_check
// forbids a non-location_time event from keeping stale venue data. The request
// says what was asked for; the row says what the constraint allowed.
//
// nil for any licence other than location_time, and nil if the columns are
// somehow incomplete -- EventVoteLicense then writes no flag at all, so nobody
// can vote. Failing closed is the right outcome for an event whose own data
// cannot say when voting is open.
//
// The clock time becomes minutes since local midnight because CEL cannot parse
// "16:00". pgtype.Time counts microseconds from midnight, so the conversion is
// exact for any value Postgres can hold in a TIME column.
func voteWindowOf(event sqlc.Event) *authz.VoteWindow {
	if event.VoteLicense != sqlc.VoteLicenseLocationTime {
		return nil
	}
	if !event.VoteWindowStart.Valid || !event.VoteWindowEnd.Valid || !event.VoteWindowTimezone.Valid {
		return nil
	}

	window := authz.VoteWindow{
		StartMinutes: int(event.VoteWindowStart.Microseconds / int64(time.Minute/time.Microsecond)),
		EndMinutes:   int(event.VoteWindowEnd.Microseconds / int64(time.Minute/time.Microsecond)),
		Timezone:     event.VoteWindowTimezone.String,
	}
	if err := window.Validate(); err != nil {
		// A TIME column cannot hold a value outside 0..1439 minutes, so this is
		// unreachable unless the column type changes. Logged rather than ignored,
		// because the fail-closed result (nobody can vote) would otherwise look
		// like a permission bug.
		log.Printf("authz: event %s has an unusable vote window, no vote tuple written: %v",
			event.PublicID.String(), err)
		return nil
	}
	return &window
}
