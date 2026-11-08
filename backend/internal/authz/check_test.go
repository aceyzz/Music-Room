package authz

import (
	"testing"
	"time"
)

// Same guarantee as TestRelationConstantsExistInModel, for the read side: a
// Permission that is not a relation in the model does not fail, it answers
// false. Every check would silently deny.
func TestPermissionConstantsExistInModel(t *testing.T) {
	_, relations := loadModel(t)

	for _, permission := range []Permission{
		PermUserViewProfile, PermUserEditProfile, PermUserManagePreferences,
		PermUserManageDevices, PermUserSendFriendRequest, PermUserReceiveInvitation,
		PermPlaylistView, PermPlaylistEditSongs, PermPlaylistSetCover,
		PermPlaylistChangeVisibility, PermPlaylistInvite,
		PermEventView, PermEventVote, PermEventSuggestSong,
		PermEventChangeSettings, PermEventInvite,
		PermQueueEntryVote,
		PermDeviceView, PermDeviceGrantControl, PermDeviceRevokeControl,
	} {
		if !relations[string(permission)] {
			t.Errorf("Permission %q is not declared in %s", permission, modelPath)
		}
	}
}

func TestNormalizePublicID(t *testing.T) {
	const canonical = "3ab93193-24a1-44ef-91a4-5d21c6ec9acb"

	for _, form := range []string{
		canonical,
		"3ab9319324a144ef91a45d21c6ec9acb", // what the DTOs used to emit
		"3AB93193-24A1-44EF-91A4-5D21C6EC9ACB",
		"  " + canonical + "  ",
	} {
		got, err := NormalizePublicID(form)
		if err != nil {
			t.Errorf("NormalizePublicID(%q): %v", form, err)
			continue
		}
		if got != canonical {
			t.Errorf("NormalizePublicID(%q) = %q, want %q", form, got, canonical)
		}
	}

	// Rejected, and it matters: a malformed id would name an object that does
	// not exist, and a nonexistent object answers every Check with a flat
	// denial -- a typo would be indistinguishable from a permission problem.
	for _, bad := range []string{
		"",
		"not-a-uuid",
		"3ab93193-24a1-44ef-91a4-5d21c6ec9ac",   // one hex digit short
		"3ab93193-24a1-44ef-91a4-5d21c6ec9acbb", // one too many
		"3ab93193-24a1-44ef-91a4-5d21c6ec9acg",  // g is not hex
		"user:3ab93193-24a1-44ef-91a4-5d21c6ec9acb",
	} {
		if got, err := NormalizePublicID(bad); err == nil {
			t.Errorf("NormalizePublicID(%q) = %q, want an error", bad, got)
		}
	}
}

// Which checks carry current_time is a cache-hit question one way and a
// correctness question the other: a conditional permission missing here denies
// every vote. The names repeat across types, so the type has to be part of it.
func TestNeedsRequestTime(t *testing.T) {
	for _, c := range []struct {
		objectType ObjectType
		permission Permission
		want       bool
	}{
		{TypeEvent, PermEventVote, true},
		{TypeEvent, PermEventSuggestSong, true},
		{TypeQueueEntry, PermQueueEntryVote, true},
		{TypeEvent, PermEventView, false},
		{TypePlaylist, PermPlaylistView, false},
		{TypePlaylist, PermPlaylistEditSongs, false},
		{TypeUser, PermUserViewProfile, false},
		{TypeDevice, PermDeviceView, false},
	} {
		if got := NeedsRequestTime(c.objectType, c.permission); got != c.want {
			t.Errorf("NeedsRequestTime(%s, %s) = %v, want %v", c.objectType, c.permission, got, c.want)
		}
	}
}

func TestRequestTimeIsUTCToTheMinute(t *testing.T) {
	paris := time.FixedZone("CEST", 2*60*60)
	got := RequestTime(time.Date(2026, 9, 15, 20, 7, 59, 999, paris))
	if want := "2026-09-15T18:07:00Z"; got != want {
		t.Errorf("RequestTime = %s, want %s", got, want)
	}
}
