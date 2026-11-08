// Package interceptor is the read half of the permission system: it decides,
// before a handler runs, whether the caller may run it.
//
// Two things happen here, in this order, and the second depends on the first.
// Authentication resolves the session token in the request metadata into an
// Identity (internal/auth/authn). Authorization then asks OpenFGA the questions
// the policy table below declares for that method. Everything the graph cannot
// answer -- soft deletes, event status, the venue radius, rank comparisons
// between two members -- stays in the handler; docs/permissions.md lists them
// per rule, in the column titled "Still checked in Go".
//
// The write half is internal/authz + internal/authz/outbox, which keeps the
// graph a faithful projection of Postgres. That half is finished. Until this
// one existed nothing read the graph at all, and every service trusted the
// user_id in the request body -- which made every rule in docs/permissions.md
// decorative, because any caller could claim to be anyone.
package interceptor

import (
	"strings"

	"example.com/music-app/internal/authz"
)

// Requirement is one question to put to OpenFGA before the handler runs, plus
// what to do with the object it names.
//
// IDField holds the object's PUBLIC UUID -- the only id a client is ever given.
// The matching int64 field is derived from the name (see StampField) and filled
// in with the resolved internal id, which is the property that makes this whole
// arrangement safe: the object that was checked and the row the handler loads
// cannot be different objects, because the handler's id is computed FROM the
// one that was checked.
type Requirement struct {
	Type       authz.ObjectType
	IDField    string
	Permission authz.Permission

	// Optional: an empty IDField skips this requirement instead of failing the
	// request. For fields that genuinely may be absent -- CreateEvent's source
	// playlist, a playback command's device.
	Optional bool

	// Resolve: fill the derived int64 field from the resolved internal id.
	// False for an object the handler does not need an id for.
	Resolve bool

	// NotFound denies with NotFound instead of PermissionDenied.
	//
	// For read permissions only, and it is not politeness: docs/permissions.md
	// §10 makes discovery and read the same permission, so an event you cannot
	// view must not be distinguishable from one that does not exist. A
	// PermissionDenied on a read is itself a disclosure -- it confirms the
	// object exists.
	NotFound bool
}

// StampField is the int64 field a Requirement's resolved id goes into.
//
// Derived rather than declared, because the proto convention is exact: every
// public field is its int64 counterpart with `_public_id` where the other has
// `_id` (playlist_public_id/playlist_id, invitee_user_public_id/
// invitee_user_id, public_id/id). TestPolicyFieldsExistOnEveryRequest checks
// the derived name against the real descriptors, so a proto that breaks the
// convention fails the build instead of failing a request.
func (r Requirement) StampField() string { return stampFieldFor(r.IDField) }

func stampFieldFor(publicIDField string) string {
	if publicIDField == "public_id" {
		return "id"
	}
	return strings.TrimSuffix(publicIDField, "public_id") + "id"
}

// Policy is what the interceptor enforces for one RPC.
type Policy struct {
	// Public skips authentication entirely. Four RPCs: the ones you call to
	// GET a session, plus Logout, which reads its own token.
	Public bool

	// CallerPublicIDField names the request field that claims to be the caller.
	// It is checked against the session and rejected when it disagrees, and its
	// int64 counterpart is filled in from the session -- no lookup, because the
	// session row already carries both ids.
	//
	// Empty on RPCs whose handler does not need to know who is calling.
	CallerPublicIDField string

	// Require lists the checks, ALL of which must pass.
	Require []Requirement

	// Residual records what this method still owes the handler, in one line.
	// It is documentation with a compiler behind it: every method listed in
	// this table is reachable, so a non-empty Residual is a statement that the
	// interceptor is knowingly not the whole answer here. Grep for it.
	Residual string
}

// policies is the whole authorization surface of this backend, one entry per
// RPC.
//
// An RPC with no entry is DENIED, with a log line naming it. That is the point
// of a table rather than a call in each handler: adding an RPC and forgetting
// to protect it is the single most likely way to open a hole, and here it fails
// closed and loudly instead of shipping unprotected. TestEveryRPCHasAPolicy
// walks the proto registry and fails the build for a missing entry, so the
// runtime denial is a backstop, not the mechanism.
var policies = map[string]Policy{
	// --- AuthService: the way in. Nothing to authenticate against yet. -------
	"/music_room.v1.AuthService/Register":             {Public: true},
	"/music_room.v1.AuthService/Login":                {Public: true},
	"/music_room.v1.AuthService/OAuthLogin":           {Public: true},
	"/music_room.v1.AuthService/RequestPasswordReset": {Public: true},
	"/music_room.v1.AuthService/ResetPassword":        {Public: true},
	// Public so that logging out with an already-dead session still succeeds
	// instead of failing Unauthenticated: the handler reads the token itself.
	"/music_room.v1.AuthService/Logout": {Public: true},
	// Authenticated, no object check. Both act on the session's own account:
	// the address a code goes to, and the account a code may verify, come
	// from the identity, never from the request. A public VerifyEmail let
	// anyone guess 6 digits until some account got verified.
	"/music_room.v1.AuthService/RequestEmailVerification": {},
	"/music_room.v1.AuthService/VerifyEmail":              {},
	"/music_room.v1.AuthService/LinkOAuthAccount":         {},
	"/music_room.v1.AuthService/UnlinkOAuthAccount":       {},
	"/music_room.v1.AuthService/ListOAuthAccounts":        {},

	// --- MusicProviderService: the catalogue is world-readable ---------------
	// docs/permissions.md §6: no `song` type exists in the model, deliberately.
	// Authentication is the whole rule.
	"/music_room.v1.MusicProviderService/GetSong":     {},
	"/music_room.v1.MusicProviderService/SearchSongs": {},

	// --- UserService --------------------------------------------------------
	"/music_room.v1.UserService/GetUser": {
		CallerPublicIDField: "viewer_public_id",
		Require: []Requirement{
			{Type: authz.TypeUser, IDField: "public_id", Permission: authz.PermUserViewProfile,
				Resolve: true, NotFound: true},
		},
		Residual: "per-field redaction, in Go from user_profiles and friendships (user/access.go)",
	},
	"/music_room.v1.UserService/UpdateUserProfile": {
		CallerPublicIDField: "user_public_id",
		Require: []Requirement{
			{Type: authz.TypeUser, IDField: "user_public_id", Permission: authz.PermUserEditProfile},
		},
	},
	"/music_room.v1.UserService/SetMusicPreferences": {
		CallerPublicIDField: "user_public_id",
		Require: []Requirement{
			{Type: authz.TypeUser, IDField: "user_public_id", Permission: authz.PermUserManagePreferences},
		},
	},
	"/music_room.v1.UserService/UploadAvatar": {
		CallerPublicIDField: "user_public_id",
		Require: []Requirement{
			{Type: authz.TypeUser, IDField: "user_public_id", Permission: authz.PermUserEditProfile},
		},
	},
	"/music_room.v1.UserService/DeleteAvatar": {
		CallerPublicIDField: "user_public_id",
		Require: []Requirement{
			{Type: authz.TypeUser, IDField: "user_public_id", Permission: authz.PermUserEditProfile},
		},
	},

	// Friends, blocks and friend requests are row-owned, not graph questions
	// (docs/permissions.md §5 and §16): both parties are named on the row, so
	// "is this mine" is a WHERE clause. Stamping the caller's id IS the check
	// here -- you cannot list someone else's friends if the id being listed is
	// always your own.
	"/music_room.v1.UserService/GetFriends":         {CallerPublicIDField: "user_public_id"},
	"/music_room.v1.UserService/ListFriendRequests": {CallerPublicIDField: "user_public_id"},
	"/music_room.v1.UserService/ListBlockedUsers":   {CallerPublicIDField: "blocker_public_id"},
	// Search answers for the caller only, and its query already leaves out
	// anyone with a block either way (see SearchUsers in db/query/social.sql).
	"/music_room.v1.UserService/SearchUsers": {CallerPublicIDField: "viewer_public_id"},
	"/music_room.v1.UserService/AcceptFriendRequest": {
		CallerPublicIDField: "addressee_public_id",
		Residual:            "the caller must be the request's addressee -- scoped by the query",
	},
	"/music_room.v1.UserService/DeclineFriendRequest": {
		CallerPublicIDField: "addressee_public_id",
		Residual:            "the caller must be the request's addressee -- scoped by the query",
	},

	"/music_room.v1.UserService/SendFriendRequest": {
		CallerPublicIDField: "requester_public_id",
		Require: []Requirement{
			{Type: authz.TypeUser, IDField: "addressee_public_id",
				Permission: authz.PermUserSendFriendRequest, Resolve: true},
		},
		Residual: "not already friends, no request already pending either way",
	},
	// Blocking is unconditional (docs/permissions.md §5): the interesting work
	// is the cascade, which the repository does. The target still has to be
	// resolved, and a block that names a deleted account is a NotFound.
	"/music_room.v1.UserService/BlockUser": {
		CallerPublicIDField: "blocker_public_id",
		Require: []Requirement{
			{Type: authz.TypeUser, IDField: "blocked_public_id", Resolve: true, NotFound: true},
		},
	},
	"/music_room.v1.UserService/UnblockUser": {
		CallerPublicIDField: "blocker_public_id",
		Require: []Requirement{
			{Type: authz.TypeUser, IDField: "blocked_public_id", Resolve: true, NotFound: true},
		},
	},

	// No permission, like blocking: the answer is about the caller's own rows
	// (their block, their friendship, their requests), and it must still
	// answer once a block exists -- user#can_view_profile refuses then, and
	// this is how a profile page learns it can offer Unblock. A block BY the
	// target is not disclosed: the query reads user_blocks one way only.
	"/music_room.v1.UserService/GetUserRelationship": {
		CallerPublicIDField: "viewer_public_id",
		Require: []Requirement{
			{Type: authz.TypeUser, IDField: "target_public_id", Resolve: true, NotFound: true},
		},
	},
	// Row-owned like the rest: the friendships row names both parties, and the
	// caller's id is stamped from the session.
	"/music_room.v1.UserService/RemoveFriend": {
		CallerPublicIDField: "user_public_id",
		Require: []Requirement{
			{Type: authz.TypeUser, IDField: "friend_public_id", Resolve: true, NotFound: true},
		},
	},

	// --- PlaylistService ----------------------------------------------------
	"/music_room.v1.PlaylistService/CreatePlaylist": {CallerPublicIDField: "owner_public_id"},
	"/music_room.v1.PlaylistService/GetPlaylist": {
		CallerPublicIDField: "viewer_public_id",
		Require: []Requirement{
			{Type: authz.TypePlaylist, IDField: "playlist_public_id",
				Permission: authz.PermPlaylistView, Resolve: true, NotFound: true},
		},
	},
	// Checked when the stream opens; the handler checks can_view again before
	// every send (docs/permissions.md §7).
	"/music_room.v1.PlaylistService/WatchPlaylist": {
		CallerPublicIDField: "viewer_public_id",
		Require: []Requirement{
			{Type: authz.TypePlaylist, IDField: "playlist_public_id",
				Permission: authz.PermPlaylistView, Resolve: true, NotFound: true},
		},
	},
	// No per-object Requirement: there is no single playlist to Check before
	// the handler runs. Authorization IS the query here -- ListObjects(can_view)
	// inside the handler -- same shape as EventService.GetMusicEvents below.
	"/music_room.v1.PlaylistService/ListPlaylists": {
		CallerPublicIDField: "viewer_public_id",
		Residual:            "can_view is enforced via ListObjects in the handler, not a Requirement",
	},
	// Same shape as ListPlaylists: ListObjects(can_view) in the handler.
	"/music_room.v1.PlaylistService/ListLibraryPlaylists": {
		CallerPublicIDField: "viewer_public_id",
		Residual:            "can_view is enforced via ListObjects in the handler, not a Requirement",
	},
	// No per-object Requirement either: public playlists only, filtered in
	// SQL on playlists.visibility, which the OpenFGA wildcard is written from.
	"/music_room.v1.PlaylistService/SearchPublicPlaylists": {
		CallerPublicIDField: "viewer_public_id",
		Residual:            "public playlists only: the SQL filter on visibility is the authorization",
	},
	"/music_room.v1.PlaylistService/DeletePlaylist": {
		Require: []Requirement{
			{Type: authz.TypePlaylist, IDField: "playlist_public_id",
				Permission: authz.PermPlaylistDelete, Resolve: true},
		},
	},
	"/music_room.v1.PlaylistService/TransferPlaylistOwnership": {
		CallerPublicIDField: "current_owner_user_public_id",
		Require: []Requirement{
			{Type: authz.TypePlaylist, IDField: "playlist_public_id",
				Permission: authz.PermPlaylistTransferOwnership, Resolve: true},
			{Type: authz.TypeUser, IDField: "new_owner_user_public_id", Resolve: true, NotFound: true},
		},
		Residual: "new_owner_user_id must already be a member -- scoped by the query",
	},
	"/music_room.v1.PlaylistService/ListPlaylistOpsSince": {
		CallerPublicIDField: "viewer_public_id",
		Require: []Requirement{
			{Type: authz.TypePlaylist, IDField: "playlist_public_id",
				Permission: authz.PermPlaylistView, Resolve: true, NotFound: true},
		},
	},
	"/music_room.v1.PlaylistService/AddSongToPlaylist": {
		CallerPublicIDField: "user_public_id",
		Require: []Requirement{
			{Type: authz.TypePlaylist, IDField: "playlist_public_id",
				Permission: authz.PermPlaylistEditSongs, Resolve: true},
		},
		Residual: "the three-step revision transaction (docs/data-model.md §13)",
	},
	"/music_room.v1.PlaylistService/RemoveSongFromPlaylist": {
		CallerPublicIDField: "user_public_id",
		Require: []Requirement{
			{Type: authz.TypePlaylist, IDField: "playlist_public_id",
				Permission: authz.PermPlaylistEditSongs, Resolve: true},
		},
		Residual: "playlist_song_id must belong to this playlist -- scoped by the query",
	},
	"/music_room.v1.PlaylistService/MoveSongInPlaylist": {
		CallerPublicIDField: "user_public_id",
		Require: []Requirement{
			{Type: authz.TypePlaylist, IDField: "playlist_public_id",
				Permission: authz.PermPlaylistEditSongs, Resolve: true},
		},
		Residual: "playlist_song_id and after_playlist_song_id must belong to this playlist -- scoped by the query",
	},
	"/music_room.v1.PlaylistService/SetPlaylistVisibility": {
		Require: []Requirement{
			{Type: authz.TypePlaylist, IDField: "playlist_public_id",
				Permission: authz.PermPlaylistChangeVisibility, Resolve: true},
		},
	},
	"/music_room.v1.PlaylistService/SetPlaylistEditLicense": {
		Require: []Requirement{
			{Type: authz.TypePlaylist, IDField: "playlist_public_id",
				Permission: authz.PermPlaylistChangeLicense, Resolve: true},
		},
	},
	"/music_room.v1.PlaylistService/RenamePlaylist": {
		Require: []Requirement{
			{Type: authz.TypePlaylist, IDField: "playlist_public_id",
				Permission: authz.PermPlaylistRename, Resolve: true},
		},
	},
	"/music_room.v1.PlaylistService/SetPlaylistCover": {
		CallerPublicIDField: "user_public_id",
		Require: []Requirement{
			{Type: authz.TypePlaylist, IDField: "playlist_public_id",
				Permission: authz.PermPlaylistSetCover, Resolve: true},
		},
	},
	"/music_room.v1.PlaylistService/DeletePlaylistCover": {
		CallerPublicIDField: "user_public_id",
		Require: []Requirement{
			{Type: authz.TypePlaylist, IDField: "playlist_public_id",
				Permission: authz.PermPlaylistSetCover, Resolve: true},
		},
	},
	// Two objects, two checks (docs/permissions.md §9): may you invite to this
	// playlist, and may this person be invited at all -- the second is where a
	// block between the two users stops the invitation.
	"/music_room.v1.PlaylistService/ListPlaylistMembers": {
		CallerPublicIDField: "viewer_public_id",
		Require: []Requirement{
			{Type: authz.TypePlaylist, IDField: "playlist_public_id",
				Permission: authz.PermPlaylistView, Resolve: true, NotFound: true},
		},
	},
	"/music_room.v1.PlaylistService/InviteToPlaylist": {
		CallerPublicIDField: "inviter_user_public_id",
		Require: []Requirement{
			{Type: authz.TypePlaylist, IDField: "playlist_public_id",
				Permission: authz.PermPlaylistInvite, Resolve: true},
			{Type: authz.TypeUser, IDField: "invitee_user_public_id",
				Permission: authz.PermUserReceiveInvitation, Resolve: true},
		},
		Residual: "no invitation already pending for this invitee",
	},

	// --- EventService -------------------------------------------------------
	"/music_room.v1.EventService/CreateEvent": {
		CallerPublicIDField: "host_public_id",
		Require: []Requirement{
			// Seeding from a playlist is a READ of that playlist. Skipping it
			// would let anyone copy a private playlist's contents into a public
			// event -- a full disclosure through a feature that does not look
			// like a read (docs/permissions.md §13).
			{Type: authz.TypePlaylist, IDField: "source_playlist_public_id",
				Permission: authz.PermPlaylistView, Optional: true, Resolve: true, NotFound: true},
		},
	},
	"/music_room.v1.EventService/GetMusicEvent": {
		CallerPublicIDField: "viewer_public_id",
		Require: []Requirement{
			{Type: authz.TypeEvent, IDField: "public_id",
				Permission: authz.PermEventView, Resolve: true, NotFound: true},
		},
	},
	// Stamping the caller here is what makes the listing safe without a filter:
	// user_id can only ever be the caller's own, so every event it returns is
	// one the caller hosts. It also narrows the RPC -- it used to accept any
	// user_id and hand back that user's private events too. Browsing someone
	// else's PUBLIC events is a different query and wants ListObjects(can_view),
	// not a Check (docs/permissions.md §10).
	// No per-object Requirement, same shape as PlaylistService.ListPlaylists
	// above: event#can_view is enforced via ListObjects inside the handler,
	// not a Check on a single object -- there is no single object here.
	"/music_room.v1.EventService/GetMusicEvents": {
		CallerPublicIDField: "user_public_id",
		Residual:            "can_view is enforced via ListObjects in the handler, not a Requirement",
	},
	"/music_room.v1.EventService/ListEventMembers": {
		CallerPublicIDField: "viewer_public_id",
		Require: []Requirement{
			{Type: authz.TypeEvent, IDField: "event_public_id",
				Permission: authz.PermEventView, Resolve: true, NotFound: true},
		},
	},
	"/music_room.v1.EventService/ListEventQueue": {
		CallerPublicIDField: "viewer_public_id",
		Require: []Requirement{
			{Type: authz.TypeEvent, IDField: "event_public_id",
				Permission: authz.PermEventView, Resolve: true, NotFound: true},
		},
	},
	"/music_room.v1.EventService/GetEventPlayback": {
		CallerPublicIDField: "viewer_public_id",
		Require: []Requirement{
			{Type: authz.TypeEvent, IDField: "event_public_id",
				Permission: authz.PermEventView, Resolve: true, NotFound: true},
		},
	},
	// Checked when the stream opens; the handler checks can_view again before
	// every send (docs/permissions.md §7).
	"/music_room.v1.EventService/WatchEvent": {
		CallerPublicIDField: "viewer_public_id",
		Require: []Requirement{
			{Type: authz.TypeEvent, IDField: "event_public_id",
				Permission: authz.PermEventView, Resolve: true, NotFound: true},
		},
	},
	// No permission on event_public_id: it is only resolved for the
	// handler's own use (fetching the event for the response, listing the
	// queue) -- can_remove is asymmetric (the suggester OR the host/admin,
	// see authz/model.fga's `suggester or can_manage_queue from parent`),
	// so the ONE question worth asking is on the entry itself, which
	// already resolves through its parent for the host/admin half.
	"/music_room.v1.EventService/RemoveQueueEntry": {
		CallerPublicIDField: "user_public_id",
		Require: []Requirement{
			{Type: authz.TypeEvent, IDField: "event_public_id", Resolve: true, NotFound: true},
			// No NotFound:true here, unlike CastVote's queue_entry Requirement:
			// can_remove is a write permission, not a read (docs/permissions.md
			// §10's NotFound-for-reads rule), and a member who can already SEE
			// this entry (ListEventQueue) getting a 404 when they lack
			// can_remove would be a confusing, inconsistent answer about
			// something they just listed.
			{Type: authz.TypeQueueEntry, IDField: "queue_entry_public_id",
				Permission: authz.PermQueueEntryRemove, Resolve: true},
		},
		Residual: "entry status must be queued -- scoped by the query",
	},
	"/music_room.v1.EventService/SetEventVisibility": {
		CallerPublicIDField: "user_public_id",
		Require: []Requirement{
			{Type: authz.TypeEvent, IDField: "event_public_id",
				Permission: authz.PermEventChangeSettings, Resolve: true},
		},
	},
	"/music_room.v1.EventService/SetEventVoteLicense": {
		CallerPublicIDField: "user_public_id",
		Require: []Requirement{
			{Type: authz.TypeEvent, IDField: "event_public_id",
				Permission: authz.PermEventChangeSettings, Resolve: true},
		},
		Residual: "location_time requires the venue and window columns to be present",
	},
	"/music_room.v1.EventService/InviteToEvent": {
		CallerPublicIDField: "inviter_user_public_id",
		Require: []Requirement{
			{Type: authz.TypeEvent, IDField: "event_public_id",
				Permission: authz.PermEventInvite, Resolve: true},
			{Type: authz.TypeUser, IDField: "invitee_user_public_id",
				Permission: authz.PermUserReceiveInvitation, Resolve: true},
		},
	},
	// can_suggest_song and can_vote carry the vote licence, including the
	// within_vote_window condition -- which is why the interceptor supplies
	// current_time on these checks (authz.NeedsRequestTime). The venue radius is NOT in the graph (CEL has
	// no geospatial functions) and stays in the handler: a pass here means "in
	// the window", never "at the venue".
	"/music_room.v1.EventService/SuggestSong": {
		CallerPublicIDField: "user_public_id",
		Require: []Requirement{
			{Type: authz.TypeEvent, IDField: "event_public_id",
				Permission: authz.PermEventSuggestSong, Resolve: true},
		},
		Residual: "events.status in (scheduled, live); venue radius under a location_time licence",
	},
	"/music_room.v1.EventService/CastVote": {
		CallerPublicIDField: "user_public_id",
		Require: []Requirement{
			{Type: authz.TypeEvent, IDField: "event_public_id",
				Permission: authz.PermEventVote, Resolve: true},
			// Also on the entry, which resolves through its parent event: this
			// is what makes an entry borrowed from ANOTHER event fail, rather
			// than relying on the vote query to scope by both ids.
			{Type: authz.TypeQueueEntry, IDField: "queue_entry_public_id",
				Permission: authz.PermQueueEntryVote, Resolve: true, NotFound: true},
		},
		Residual: "entry status must be queued; venue radius under a location_time licence",
	},
	// Playback is the one action with TWO legitimate routes: the event side
	// (host or admin) or a control licence on the device, whose relation depends
	// on which button was pressed. An OR of two checks over two object types is
	// not something this table can express, and collapsing it to one would
	// either lock out delegates or ignore the licence -- so it stays in the
	// handler, where the action is known. docs/permissions.md §12.
	// The device is the event's speaker, read by the handler: the request names
	// none.
	"/music_room.v1.EventService/PlayNextInEventQueue": {
		CallerPublicIDField: "user_public_id",
		Require: []Requirement{
			{Type: authz.TypeEvent, IDField: "event_public_id", Resolve: true, NotFound: true},
		},
		Residual: "the host, or a licence for this event on its speaker device -- in SQL (event/access.go)",
	},
	"/music_room.v1.EventService/SetEventPlayback": {
		CallerPublicIDField: "user_public_id",
		Require: []Requirement{
			{Type: authz.TypeEvent, IDField: "event_public_id", Resolve: true, NotFound: true},
		},
		Residual: "the host, or a licence for this event on its speaker device -- in SQL (event/access.go)",
	},
	// The one lifecycle transition left to a request (docs/permissions.md
	// §13; the host's first play makes an event live): can_change_status
	// says WHO (host or admin), the legal-edge check is a compare-and-swap in
	// the query itself, not something a Requirement can express -- "state
	// machines are not relationships".
	"/music_room.v1.EventService/EndEvent": {
		Require: []Requirement{
			{Type: authz.TypeEvent, IDField: "event_public_id",
				Permission: authz.PermEventChangeStatus, Resolve: true},
		},
		Residual: "must not have ended already",
	},
	// can_delete is host-only (authz/model.fga), unlike can_change_status
	// above (host OR admin) -- same asymmetry as PlaylistService's
	// can_delete vs can_manage_members.
	"/music_room.v1.EventService/DeleteEvent": {
		Require: []Requirement{
			{Type: authz.TypeEvent, IDField: "event_public_id",
				Permission: authz.PermEventDelete, Resolve: true},
		},
	},

	// --- DelegationService --------------------------------------------------
	// A device is not an object yet at registration time, so the permission is
	// on the account: can_manage_devices resolves through account_owner.
	"/music_room.v1.DelegationService/RegisterDevice": {
		CallerPublicIDField: "user_public_id",
		Require: []Requirement{
			{Type: authz.TypeUser, IDField: "user_public_id", Permission: authz.PermUserManageDevices},
		},
	},
	"/music_room.v1.DelegationService/ListMyDevices": {CallerPublicIDField: "user_public_id"},
	"/music_room.v1.DelegationService/GrantDeviceControl": {
		CallerPublicIDField: "granter_user_public_id",
		Require: []Requirement{
			{Type: authz.TypeDevice, IDField: "device_public_id",
				Permission: authz.PermDeviceGrantControl, Resolve: true},
			{Type: authz.TypeUser, IDField: "grantee_user_public_id", Resolve: true, NotFound: true},
			// Required: a licence is for one event, never for every one (00021).
			{Type: authz.TypeEvent, IDField: "event_public_id", Resolve: true, NotFound: true},
		},
		// Friends-only is a write-time precondition with nothing for a Check to
		// re-evaluate -- that is exactly why unfriending and blocking have to
		// actively revoke grants (docs/permissions.md §14).
		Residual: "the grantee must be a friend of the granter",
	},
	"/music_room.v1.DelegationService/RevokeDeviceControl": {
		CallerPublicIDField: "revoker_user_public_id",
		Require: []Requirement{
			{Type: authz.TypeDevice, IDField: "device_public_id",
				Permission: authz.PermDeviceRevokeControl, Resolve: true},
		},
		Residual: "license_id must belong to this device -- scoped by the query",
	},
	"/music_room.v1.DelegationService/ListDeviceControlLicenses": {
		CallerPublicIDField: "viewer_user_public_id",
		Require: []Requirement{
			{Type: authz.TypeDevice, IDField: "device_public_id",
				Permission: authz.PermDeviceView, Resolve: true, NotFound: true},
		},
	},
	"/music_room.v1.DelegationService/SetEventSpeaker": {
		CallerPublicIDField: "host_user_public_id",
		Require: []Requirement{
			{Type: authz.TypeEvent, IDField: "event_public_id",
				Permission: authz.PermEventChangeSettings, Resolve: true},
			// A device of the host's own: its owner is the one who may grant
			// control of it, and the event's licences move onto it.
			{Type: authz.TypeDevice, IDField: "device_public_id",
				Permission: authz.PermDeviceGrantControl, Resolve: true},
		},
		Residual: "not on an ended event",
	},
}

// allowedWithoutPolicy is the escape hatch, and it holds exactly one kind of
// thing: gRPC's own machinery.
//
// Server reflection is a streaming RPC that serves the schema -- the same
// schema that sits in proto/ in this repository -- and grpcurl cannot work
// without it. It is registered in cmd/main.go for that reason and should not be
// in production; turning it off is a main.go decision, not an authorization one.
var allowedWithoutPolicy = map[string]bool{
	"/grpc.reflection.v1.ServerReflection/ServerReflectionInfo":      true,
	"/grpc.reflection.v1alpha.ServerReflection/ServerReflectionInfo": true,
}
