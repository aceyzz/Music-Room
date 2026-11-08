package authz

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/openfga/go-sdk/client"
)

// Permission is a COMPUTED relation from the model -- the read side of this
// package.
//
// It is a distinct type from Relation on purpose. Relation names the directly
// assignable relations, the only ones a Tuple may carry; Permission names the
// derived ones (can_view, can_edit_songs, ...), the only ones worth asking
// about. Keeping them apart means the compiler refuses the two mistakes that
// are otherwise silent at compile time and confusing at runtime: writing a
// tuple for a relation OpenFGA computes (rejected at the API boundary), and
// checking a raw assignable relation, which answers a narrower question than
// the caller meant -- `viewer` instead of `can_view` misses the owner, every
// admin, and a public playlist.
//
// Only permissions with a call site in the policy table are listed. The model
// declares more; adding a constant here with nothing behind it invites the
// reader to assume something enforces it.
type Permission string

const (
	// --- user ---------------------------------------------------------------
	PermUserViewProfile       Permission = "can_view_profile"
	PermUserEditProfile       Permission = "can_edit_profile"
	PermUserManagePreferences Permission = "can_manage_preferences"
	PermUserManageDevices     Permission = "can_manage_devices"
	PermUserSendFriendRequest Permission = "can_send_friend_request"
	PermUserReceiveInvitation Permission = "can_receive_invitation"

	// --- playlist -----------------------------------------------------------
	PermPlaylistView              Permission = "can_view"
	PermPlaylistRename            Permission = "can_rename"
	PermPlaylistEditSongs         Permission = "can_edit_songs"
	PermPlaylistSetCover          Permission = "can_set_cover"
	PermPlaylistChangeVisibility  Permission = "can_change_visibility"
	PermPlaylistChangeLicense     Permission = "can_change_license"
	PermPlaylistInvite            Permission = "can_invite"
	PermPlaylistManageMembers     Permission = "can_manage_members"
	PermPlaylistDelete            Permission = "can_delete"
	PermPlaylistTransferOwnership Permission = "can_transfer_ownership"

	// --- event --------------------------------------------------------------
	PermEventView           Permission = "can_view"
	PermEventVote           Permission = "can_vote"
	PermEventSuggestSong    Permission = "can_suggest_song"
	PermEventChangeSettings Permission = "can_change_settings"
	PermEventChangeStatus   Permission = "can_change_status"
	PermEventInvite         Permission = "can_invite"
	PermEventDelete         Permission = "can_delete"

	// --- queue_entry --------------------------------------------------------
	PermQueueEntryVote   Permission = "can_vote"
	PermQueueEntryRemove Permission = "can_remove"

	// --- device -------------------------------------------------------------
	PermDeviceView          Permission = "can_view"
	PermDeviceGrantControl  Permission = "can_grant_control"
	PermDeviceRevokeControl Permission = "can_revoke_control"
)

// CheckRequest is one authorization question: may Subject do Permission on
// Object.
//
// Context carries the CEL condition parameters the *request* supplies, as
// opposed to those frozen onto the tuple when it was written. The split is
// listed in docs/authz-sync-guide.md; in practice it is current_time for
// within_vote_window.
type CheckRequest struct {
	Subject    string
	Permission Permission
	Object     string
	Context    map[string]any
}

// Check answers one question. It returns the server's answer, or an error --
// and never conflates the two.
//
// There is deliberately no fail-open or fail-closed policy in here. The write
// path retries forever because a lost tuple is invisible; a check has the
// opposite shape -- it has to answer *now*, and the safe answer to "I could not
// reach OpenFGA" is a denial. That is the caller's decision to take and to log,
// because only the caller knows which request is being denied. The interceptor
// (internal/interceptor) is that caller: it maps any error here to
// PermissionDenied and logs it.
func (c *Client) Check(ctx context.Context, req CheckRequest) (bool, error) {
	body := client.ClientCheckRequest{
		User:     req.Subject,
		Relation: string(req.Permission),
		Object:   req.Object,
	}
	if len(req.Context) > 0 {
		context := req.Context
		body.Context = &context
	}

	response, err := c.fga.Check(ctx).Body(body).Execute()
	if err != nil {
		return false, fmt.Errorf("openfga check %s#%s@%s: %w",
			req.Object, req.Permission, req.Subject, err)
	}
	return response.GetAllowed(), nil
}

// ListObjects answers a different question than Check: not "may this subject
// act on this one object", but "which objects of this type does the subject
// hold the permission on at all" -- the ids come back already filtered by
// OpenFGA, and Postgres is only asked to hydrate them (see
// PlaylistService.ListPlaylists and its GetPlaylistsByPublicIDs query).
//
// It returns bare public ids, not "type:id" -- every caller immediately wants
// the id alone to feed a SQL `= ANY(...)`, and stripping the prefix once here
// beats every call site doing it.
//
// Same fail-closed shape as Check: an OpenFGA error must not read as "no
// objects", so it is returned rather than swallowed into an empty slice --
// the caller decides, exactly as documented on Check.
func (c *Client) ListObjects(ctx context.Context, subject string, permission Permission, objectType ObjectType) ([]string, error) {
	response, err := c.fga.ListObjects(ctx).Body(client.ClientListObjectsRequest{
		User:     subject,
		Relation: string(permission),
		Type:     string(objectType),
	}).Execute()
	if err != nil {
		return nil, fmt.Errorf("openfga list_objects %s#%s@%s: %w", objectType, permission, subject, err)
	}

	objects := response.GetObjects()
	prefix := string(objectType) + ":"
	ids := make([]string, len(objects))
	for i, object := range objects {
		ids[i] = strings.TrimPrefix(object, prefix)
	}
	return ids, nil
}

// NeedsRequestTime reports whether a Check of this permission can reach a
// conditional tuple, and so needs current_time in its request context.
//
// The set is every (type, permission) whose computation in authz/model.fga
// reaches `within_vote_window` AND has a call site. Keyed
// by type as well, because the same name means different things on different
// types: event#can_vote reaches the vote window, playlist#can_view reaches
// nothing.
//
// Why not send it everywhere, as the interceptor used to: OpenFGA's check
// cache keys on the request context, so a timestamp on a check that never
// reads it only makes every key unique and the cache useless. And a
// permission missing from this set fails closed, not open -- the conditional
// tuple cannot be evaluated without its parameter, which reads as a denial.
func NeedsRequestTime(objectType ObjectType, permission Permission) bool {
	return conditionalPermissions[objectType][permission]
}

var conditionalPermissions = map[ObjectType]map[Permission]bool{
	TypeEvent:      {PermEventVote: true, PermEventSuggestSong: true},
	TypeQueueEntry: {PermQueueEntryVote: true}, // can_vote from parent
}

// RequestTime formats now the way the conditions expect it.
//
// Both conditions take a `current_time: timestamp`, and OpenFGA parses a
// timestamp parameter from an RFC 3339 string. UTC rather than local: the
// venue's zone is a separate parameter on the tuple, and getHours(zone) does
// the conversion inside CEL.
//
// Truncated to the minute, so that every check of the same question within a
// minute has the same context and can share a cache entry. Exact for
// within_vote_window, which only reads hours and minutes.
func RequestTime(now time.Time) string {
	return now.UTC().Truncate(time.Minute).Format(time.RFC3339)
}
