// Package authz projects Postgres rows onto the OpenFGA permission graph.
//
// The direction is one-way and mechanical: Postgres is the source of truth
// (docs/data-model.md 14), and every tuple here is a transcription of a row.
// Nothing in this package decides policy -- policy lives in authz/model.fga, and
// the plain-language rules with their residual Go checks live in
// docs/permissions.md. Read that before assuming a Check is the whole answer.
//
// The one deliberate exception to "tuples transcribe rows" is user#blocked, where
// a single directional user_blocks row produces two tuples.
package authz

// ObjectType is one of the six types declared in authz/model.fga.
//
// Constants rather than strings at call sites: a mistyped type produces a tuple
// that writes successfully and then never matches any Check. That failure is
// silent, permissive, and extremely tedious to find.
type ObjectType string

const (
	TypeUser       ObjectType = "user"
	TypePlaylist   ObjectType = "playlist"
	TypeEvent      ObjectType = "event"
	TypeQueueEntry ObjectType = "queue_entry"
	TypeDevice     ObjectType = "device"
	TypeImage      ObjectType = "image"
)

// Everyone is the public wildcard. In the model it is the only thing that may
// occupy the subject side of a [user:*] relation.
const Everyone = "user:*"

// Object names an FGA object as "<type>:<id>".
//
// The id is always the PUBLIC UUID the API exposes, never the BIGSERIAL primary
// key. That is a load-bearing decision, not a style one: an authorization check
// has to be answerable from the request alone, and internal ids would force a
// public-to-internal lookup in Postgres before every Check -- a database round
// trip on the hot path of the service whose entire purpose is to avoid one.
//
// Consequence: a table whose rows become FGA objects needs a public_id column.
// devices, images and event_queue_entries did not have one, which is what
// 00017_public_ids.sql exists for -- without it, half the model was unwritable.
func Object(t ObjectType, publicID string) string {
	return string(t) + ":" + publicID
}

// UserRef is Object(TypeUser, id). Common enough to be worth the shorthand, and
// it reads better on the subject side of a tuple.
func UserRef(publicID string) string {
	return Object(TypeUser, publicID)
}

// Relation is a relation name from the model.
//
// Only DIRECTLY ASSIGNABLE relations get constants -- the ones declared with a
// type restriction, like `define owner: [user]`. Computed relations
// (can_view_profile, can_edit_songs, ...) are derived by the server from the
// tuples below and cannot be written. Giving them constants here would invite
// writing one, which OpenFGA rejects at the API boundary, but only at runtime.
type Relation string

const (
	// --- user ---------------------------------------------------------------
	RelAccountOwner Relation = "account_owner"
	RelAnyone       Relation = "anyone"
	RelBlocked      Relation = "blocked"

	// --- playlist -----------------------------------------------------------
	RelPlaylistOwner  Relation = "owner"
	RelPlaylistAdmin  Relation = "admin"
	RelPlaylistEditor Relation = "editor"
	RelPlaylistViewer Relation = "viewer"
	RelPlaylistPublic Relation = "public"
	RelOpenEdit       Relation = "open_edit"

	// --- event --------------------------------------------------------------
	RelEventHost   Relation = "host"
	RelEventAdmin  Relation = "admin"
	RelEventEditor Relation = "editor"
	RelEventViewer Relation = "viewer"
	RelEventPublic Relation = "public"
	// Mutually exclusive: vote_license is one enum column, so exactly one of
	// these exists per event and a license change must delete the other two --
	// in the same Change, for the reason given on Change itself.
	RelOpenVote    Relation = "open_vote"
	RelInvitedVote Relation = "invited_vote"
	RelWindowVote  Relation = "window_vote"

	// --- queue_entry --------------------------------------------------------
	RelParent    Relation = "parent"
	RelSuggester Relation = "suggester"

	// --- device -------------------------------------------------------------
	RelDeviceOwner Relation = "owner"

	// --- image --------------------------------------------------------------
	RelImageOwner    Relation = "owner"
	RelImagePublic   Relation = "public"
	RelPlaylistCover Relation = "playlist_cover_of"
	RelEventCover    Relation = "event_cover_of"
	RelOriginalImage Relation = "original"
)

// Condition names a CEL condition from the model plus the context Go supplies.
// Nil on the overwhelming majority of tuples; only window_vote and the device
// *_grant relations carry one.
type Condition struct {
	Name    string         `json:"name"`
	Context map[string]any `json:"context,omitempty"`
}

// Tuple is one relationship: subject, relation, object.
type Tuple struct {
	User      string     `json:"user"`
	Relation  Relation   `json:"relation"`
	Object    string     `json:"object"`
	Condition *Condition `json:"condition,omitempty"`
}

// Change is one logical permission change and the unit of everything downstream:
// one outbox row, one OpenFGA Write call, one retry.
//
// Writes and deletes travel together because some of them are only CORRECT
// together. Profile visibility is the clearest case: the model encodes a
// tri-state as two wildcard flags where neither present means private and both
// present reads as public. Moving a field from public to friends is a delete plus
// a write, and applying them separately -- in either order -- passes through a
// state that is wrong, one of which is wrong in the permissive direction.
//
// Splitting a Change into two outbox rows reintroduces exactly that hazard, which
// is why the outbox stores the whole thing as one JSONB payload.
type Change struct {
	Writes  []Tuple `json:"writes,omitempty"`
	Deletes []Tuple `json:"deletes,omitempty"`

	// ObjectKey is the FGA object this change concerns; it becomes its own
	// column so the worker can keep changes to the same object in order.
	ObjectKey string `json:"-"`
	// Origin is a short label for whoever is debugging a stuck row.
	Origin string `json:"-"`
}

// IsEmpty reports whether there is nothing to do. Worth checking before touching
// the outbox: an empty Change would otherwise cost a row, a write and a retry
// budget to accomplish nothing.
func (c Change) IsEmpty() bool {
	return len(c.Writes) == 0 && len(c.Deletes) == 0
}

// Origins for the outbox row. Short, stable, greppable.
//
// One per mutation that owes tuples, not one per object type: when a row is stuck
// this is the only column that says which handler put it there. Reusing a label
// across two handlers costs exactly the thing it exists to provide.
const (
	OriginRegister     = "register"
	OriginBlock        = "block"
	OriginUnblock      = "unblock"
	OriginAvatarUpload = "avatar_upload"
	OriginAvatarDelete = "avatar_delete"

	OriginPlaylistCreate     = "playlist_create"
	OriginPlaylistVisibility = "playlist_visibility"
	OriginPlaylistLicense    = "playlist_license"
	OriginPlaylistMember     = "playlist_member"
	OriginPlaylistCover      = "playlist_cover"
	OriginPlaylistCoverClear = "playlist_cover_clear"

	OriginEventCreate     = "event_create"
	OriginEventLicense    = "event_license"
	OriginEventMember     = "event_member"
	OriginEventVisibility = "event_visibility"

	OriginQueueSuggest = "queue_suggest"

	OriginDeviceRegister = "device_register"
)

// NewUser is the tuple set an account needs from the moment it exists.
//
// Both are easy to overlook and both fail in ways that look like bugs
// somewhere else:
//
//   - account_owner is a DIRECT relation in the model, so without the self-tuple
//     a registered user cannot edit their own profile, manage their sessions or
//     register a device. Every can_* on the account resolves through it.
//   - anyone is also direct. can_view_profile, can_send_friend_request and
//     can_receive_invitation are all `anyone but not blocked`, so without this
//     tuple the account is invisible to every other user in the system.
//
// The per-field profile visibility is not in the graph: GetUser applies it from
// the user_profiles row (internal/user/access.go).
func NewUser(userPublicID string) Change {
	object := UserRef(userPublicID)
	return Change{
		ObjectKey: object, Origin: OriginRegister,
		Writes: []Tuple{
			{User: object, Relation: RelAccountOwner, Object: object},
			{User: Everyone, Relation: RelAnyone, Object: object},
		},
	}
}
