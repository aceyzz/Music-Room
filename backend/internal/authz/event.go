package authz

import "fmt"

// Tuple constructors for the event and queue_entry types.
//
// Events differ from playlists in one way that matters: the vote licence is a
// THREE-state enum, spelled as three mutually exclusive wildcard flags. Exactly
// one may exist, so a licence change is always a write plus two deletes in the
// same Change -- split them across two outbox rows and the graph passes through
// a state where two licences are active at once, which resolves as the union of
// both. See exclusiveFor().
//
// The third state also carries data. `location_time` is a wall-clock window at a
// venue, and CEL has no geospatial functions, so the model covers the TIME half
// as a condition on the tuple and leaves the RADIUS as a residual Go check. A
// Check returning true for can_vote_window means "inside the window", never "at
// the venue" -- docs/permissions.md is the authority on what else must hold.

var eventRoles = map[MemberRole]Relation{
	// owner maps to host: the model calls the event's owner its host, while
	// event_members reuses the shared member_role enum, which spells it owner.
	RoleOwner:  RelEventHost,
	RoleAdmin:  RelEventAdmin,
	RoleEditor: RelEventEditor,
	RoleViewer: RelEventViewer,
}

var eventRoleRelations = []Relation{
	RelEventHost, RelEventAdmin, RelEventEditor, RelEventViewer,
}

// voteLicenseRelations is the mutually exclusive set. Order is fixed so the
// tuples a given licence produces are deterministic and therefore testable.
var voteLicenseRelations = []Relation{RelOpenVote, RelInvitedVote, RelWindowVote}

// VoteWindow is the data the within_vote_window condition needs, already in the
// form the condition expects.
//
// Minutes since local midnight rather than a clock string, because CEL cannot
// parse "16:00". The timezone travels with it because the venue's zone is not the
// server's and getHours() requires one.
//
// Both bounds must land in 0..1439: the condition's modular arithmetic relies on
// its operands staying positive, since CEL's % truncates toward zero. Validate()
// is the enforcement, and it runs at write time because a bad value here does not
// fail the write -- it silently makes every window check answer the wrong thing.
type VoteWindow struct {
	StartMinutes int
	EndMinutes   int
	Timezone     string
}

const minutesPerDay = 24 * 60

// Validate rejects a window the condition cannot evaluate correctly.
//
// start == end is allowed and means an EMPTY window, not a full day -- the
// condition's `< 0` comparison is never true. That reading is deliberate and
// documented in model.fga; callers that mean "always" should use
// VoteLicenseEveryone instead.
func (w VoteWindow) Validate() error {
	if w.StartMinutes < 0 || w.StartMinutes >= minutesPerDay {
		return fmt.Errorf("vote window start %d is outside 0..1439", w.StartMinutes)
	}
	if w.EndMinutes < 0 || w.EndMinutes >= minutesPerDay {
		return fmt.Errorf("vote window end %d is outside 0..1439", w.EndMinutes)
	}
	if w.Timezone == "" {
		return fmt.Errorf("vote window has no timezone, so its bounds mean nothing")
	}
	return nil
}

func (w VoteWindow) condition() *Condition {
	return &Condition{
		Name: "within_vote_window",
		Context: map[string]any{
			"window_start_minutes": w.StartMinutes,
			"window_end_minutes":   w.EndMinutes,
			"venue_timezone":       w.Timezone,
		},
	}
}

// voteLicenseTuples maps the licence column onto its flag.
//
// window is only read for location_time, and a nil window there produces no
// write at all: the caller has an event whose CHECK constraint guarantees the
// window columns are set, so nil means a bug upstream, and the fail-closed
// outcome (nobody can vote) is the one to have while it is found.
func voteLicenseTuples(object string, license VoteLicense, window *VoteWindow) (writes, deletes []Tuple) {
	switch license {
	case VoteLicenseEveryone:
		return exclusive(object, voteLicenseRelations, RelOpenVote, nil)
	case VoteLicenseInvitedOnly:
		return exclusive(object, voteLicenseRelations, RelInvitedVote, nil)
	case VoteLicenseLocationTime:
		if window == nil {
			return exclusive(object, voteLicenseRelations, "", nil)
		}
		return exclusive(object, voteLicenseRelations, RelWindowVote, window.condition())
	default:
		return exclusive(object, voteLicenseRelations, "", nil)
	}
}

// NewEvent is the tuple set an event needs from the moment it exists.
//
// Unlike NewPlaylist this DOES carry deletes -- the ones voteLicenseTuples
// returns for the two licences that were not chosen. They are pure overhead on a
// brand-new object, and they are kept because the alternative is a second code
// path through the licence logic whose only difference is trusting that an object
// nobody has touched yet is clean. The cost is two no-op deletes; the benefit is
// that creation and update cannot disagree.
func NewEvent(eventPublicID, hostPublicID string, visibility Visibility, license VoteLicense, window *VoteWindow) Change {
	object := Object(TypeEvent, eventPublicID)

	writes, deletes := voteLicenseTuples(object, license, window)
	writes = append([]Tuple{{
		User:     UserRef(hostPublicID),
		Relation: RelEventHost,
		Object:   object,
	}}, writes...)

	if visibility == VisibilityPublic {
		writes = append(writes, Tuple{User: Everyone, Relation: RelEventPublic, Object: object})
	}

	return Change{
		ObjectKey: object, Origin: OriginEventCreate,
		Writes: writes, Deletes: deletes,
	}
}

// EventVoteLicense swaps the licence flag. The two it did not pick are deleted in
// the same Change, which is the whole point -- see voteLicenseTuples.
// EventVisibility makes the public wildcard match the column, the same as
// PlaylistVisibility: written when public, deleted when private.
func EventVisibility(eventPublicID string, visibility Visibility) Change {
	object := Object(TypeEvent, eventPublicID)
	tuple := Tuple{User: Everyone, Relation: RelEventPublic, Object: object}

	change := Change{ObjectKey: object, Origin: OriginEventVisibility}
	if visibility == VisibilityPublic {
		change.Writes = []Tuple{tuple}
	} else {
		change.Deletes = []Tuple{tuple}
	}
	return change
}

func EventVoteLicense(eventPublicID string, license VoteLicense, window *VoteWindow) Change {
	object := Object(TypeEvent, eventPublicID)
	writes, deletes := voteLicenseTuples(object, license, window)
	return Change{
		ObjectKey: object, Origin: OriginEventLicense,
		Writes: writes, Deletes: deletes,
	}
}

// EventMember transcribes one event_members row. Same shape as its playlist
// counterpart: write the role, delete the other three.
func EventMember(eventPublicID, userPublicID string, role MemberRole) Change {
	object := Object(TypeEvent, eventPublicID)
	writes, deletes := exclusiveFor(object, UserRef(userPublicID), eventRoleRelations, eventRoles[role], nil)
	return Change{
		ObjectKey: object, Origin: OriginEventMember,
		Writes: writes, Deletes: deletes,
	}
}

// NewQueueEntry links a suggested song to its event and its suggester.
//
// `parent` is the load-bearing one: queue_entry#can_view and #can_vote are both
// `... from parent`, so an entry without it is invisible and unvotable to
// everyone including the host. The suggester tuple only grants can_remove.
//
// suggesterPublicID may be empty. event_queue_entries.suggested_by_id is nullable
// (ON DELETE SET NULL), so an entry outlives the account that suggested it -- and
// then nobody holds can_remove through `suggester`, only the host through
// `can_manage_queue from parent`. That is the correct outcome, not a gap.
func NewQueueEntry(entryPublicID, eventPublicID, suggesterPublicID string) Change {
	object := Object(TypeQueueEntry, entryPublicID)

	change := Change{ObjectKey: object, Origin: OriginQueueSuggest}
	change.Writes = append(change.Writes, Tuple{
		User:     Object(TypeEvent, eventPublicID),
		Relation: RelParent,
		Object:   object,
	})
	if suggesterPublicID != "" {
		change.Writes = append(change.Writes, Tuple{
			User:     UserRef(suggesterPublicID),
			Relation: RelSuggester,
			Object:   object,
		})
	}
	return change
}
