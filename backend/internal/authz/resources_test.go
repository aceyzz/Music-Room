package authz

import (
	"testing"
)

// Test ids. Any non-empty string works -- nothing in this package parses them --
// so they are readable rather than valid UUIDs.
const (
	ownerID    = "owner-1"
	memberID   = "member-2"
	objectID   = "object-3"
	granteeID  = "grantee-4"
	eventObjID = "event-5"
)

// relationsOf indexes a tuple slice by relation, so an assertion can name what it
// is looking for instead of an index.
func relationsOf(tuples []Tuple) map[Relation]Tuple {
	byRelation := make(map[Relation]Tuple, len(tuples))
	for _, tuple := range tuples {
		byRelation[tuple.Relation] = tuple
	}
	return byRelation
}

// allConstructors builds one Change from every constructor in the package.
//
// The list is the point: the two tests below it are properties that must hold for
// EVERY change this package can produce, and a new constructor that forgets one
// of them fails here rather than at 3am in the outbox. Adding a constructor
// without adding it to this list is the only way to escape, which is at least
// visible in review.
func allConstructors() map[string]Change {
	return map[string]Change{
		"NewUser":            NewUser(ownerID),
		"Block":              Block(ownerID, memberID),
		"Unblock":            Unblock(ownerID, memberID),
		"NewPlaylist":        NewPlaylist(objectID, ownerID, VisibilityPublic, EditLicenseEveryone),
		"PlaylistVisibility": PlaylistVisibility(objectID, VisibilityPrivate),
		"PlaylistMember":     PlaylistMember(objectID, memberID, RoleEditor),
		"NewEvent": NewEvent(objectID, ownerID, VisibilityPublic, VoteLicenseLocationTime,
			&VoteWindow{StartMinutes: 960, EndMinutes: 1320, Timezone: "Europe/Paris"}),
		"EventVoteLicense": EventVoteLicense(objectID, VoteLicenseEveryone, nil),
		"EventMember":      EventMember(objectID, memberID, RoleViewer),
		"NewQueueEntry":    NewQueueEntry(objectID, eventObjID, memberID),
		"NewDevice":        NewDevice(objectID, ownerID),
		"NewImage":         NewImage(objectID, ownerID, AvatarAttachment(), OriginAvatarUpload),
		"DeleteImage": DeleteImage(objectID, ownerID,
			PlaylistCoverAttachment("playlist-6"), OriginPlaylistCoverClear),
	}
}

// Enqueue rejects a Change with no ObjectKey, because the worker cannot order it
// -- and an unorderable change is how a stale tuple (a block, a playlist's
// visibility) survives a newer one. Origin is not enforced there, so it is enforced here: it is the only
// column that says which handler is responsible for a stuck row.
func TestEveryChangeCarriesObjectKeyAndOrigin(t *testing.T) {
	for name, change := range allConstructors() {
		if change.ObjectKey == "" {
			t.Errorf("%s produced a Change with no ObjectKey; Enqueue will reject it", name)
		}
		if change.Origin == "" {
			t.Errorf("%s produced a Change with no Origin; a stuck row would be unattributable", name)
		}
		if change.IsEmpty() {
			t.Errorf("%s produced an empty Change; it costs a row and a retry to do nothing", name)
		}
	}
}

// The failure this catches is the one the package doc warns about: a relation
// name that does not exist in the model writes successfully and then never
// matches a Check. Silent, permissive, and tedious to find -- so every relation
// any constructor can emit is checked against the real model file.
func TestEveryConstructedRelationExistsInModel(t *testing.T) {
	_, declared := loadModel(t)

	for name, change := range allConstructors() {
		for _, tuple := range append(append([]Tuple{}, change.Writes...), change.Deletes...) {
			if !declared[string(tuple.Relation)] {
				t.Errorf("%s emits relation %q, which is not declared in %s",
					name, tuple.Relation, modelPath)
			}
		}
	}
}

func TestNewPlaylistWritesTheWildcardsItsColumnsImply(t *testing.T) {
	open := relationsOf(NewPlaylist(objectID, ownerID, VisibilityPublic, EditLicenseEveryone).Writes)
	if len(open) != 3 {
		t.Fatalf("public + everyone should write owner, public and open_edit; got %d tuples", len(open))
	}
	if open[RelPlaylistOwner].User != UserRef(ownerID) {
		t.Errorf("owner tuple names %q, want %q", open[RelPlaylistOwner].User, UserRef(ownerID))
	}
	if open[RelPlaylistPublic].User != Everyone || open[RelOpenEdit].User != Everyone {
		t.Error("the public and open_edit flags must be held by the user:* wildcard")
	}

	shut := NewPlaylist(objectID, ownerID, VisibilityPrivate, EditLicenseInvitedOnly)
	if len(shut.Writes) != 1 {
		t.Errorf("private + invited_only should write the owner and nothing else; got %d tuples", len(shut.Writes))
	}
}

// A demotion that only writes the new role leaves the old, higher one standing,
// and the model resolves that as still-an-admin. So the other three must be
// deleted in the same Change.
func TestPlaylistMemberDeletesTheRolesItDidNotWrite(t *testing.T) {
	change := PlaylistMember(objectID, memberID, RoleAdmin)

	if len(change.Writes) != 1 || change.Writes[0].Relation != RelPlaylistAdmin {
		t.Fatalf("want exactly one write of admin, got %#v", change.Writes)
	}
	deleted := relationsOf(change.Deletes)
	for _, relation := range []Relation{RelPlaylistOwner, RelPlaylistEditor, RelPlaylistViewer} {
		if _, ok := deleted[relation]; !ok {
			t.Errorf("role %q was not deleted; promoting to admin would leave it in force", relation)
		}
	}
	if _, ok := deleted[RelPlaylistAdmin]; ok {
		t.Error("admin is both written and deleted in one Change")
	}
}

// An unrecognised enum value must grant nothing. It reaches this package through
// a cast, so it is reachable without a compile error.
func TestUnknownRoleGrantsNothing(t *testing.T) {
	change := PlaylistMember(objectID, memberID, MemberRole("superuser"))

	if len(change.Writes) != 0 {
		t.Errorf("an unknown role must write nothing, got %#v", change.Writes)
	}
	if len(change.Deletes) != 4 {
		t.Errorf("an unknown role must clear all four roles, got %d deletes", len(change.Deletes))
	}
}

// vote_license is one enum column, so exactly one flag may exist. Two at once
// resolves as the union of both licences -- the permissive failure.
func TestVoteLicenseIsMutuallyExclusive(t *testing.T) {
	window := &VoteWindow{StartMinutes: 960, EndMinutes: 1320, Timezone: "Europe/Paris"}

	cases := []struct {
		license VoteLicense
		want    Relation
	}{
		{VoteLicenseEveryone, RelOpenVote},
		{VoteLicenseInvitedOnly, RelInvitedVote},
		{VoteLicenseLocationTime, RelWindowVote},
	}

	for _, testCase := range cases {
		change := EventVoteLicense(objectID, testCase.license, window)

		if len(change.Writes) != 1 || change.Writes[0].Relation != testCase.want {
			t.Errorf("%s: want one write of %q, got %#v", testCase.license, testCase.want, change.Writes)
		}
		if len(change.Deletes) != 2 {
			t.Errorf("%s: want the other two flags deleted, got %d", testCase.license, len(change.Deletes))
		}
		for _, tuple := range change.Deletes {
			if tuple.Relation == testCase.want {
				t.Errorf("%s: deletes the flag it just wrote", testCase.license)
			}
			if tuple.Condition != nil {
				t.Errorf("%s: a delete carries a condition; a tuple is keyed on three parts", testCase.license)
			}
		}
	}
}

func TestWindowVoteCarriesItsCondition(t *testing.T) {
	window := &VoteWindow{StartMinutes: 960, EndMinutes: 1320, Timezone: "Europe/Paris"}
	change := EventVoteLicense(objectID, VoteLicenseLocationTime, window)

	condition := change.Writes[0].Condition
	if condition == nil {
		t.Fatal("window_vote must carry the within_vote_window condition")
	}
	if condition.Name != "within_vote_window" {
		t.Errorf("condition is %q, want within_vote_window", condition.Name)
	}
	if condition.Context["window_start_minutes"] != 960 ||
		condition.Context["window_end_minutes"] != 1320 ||
		condition.Context["venue_timezone"] != "Europe/Paris" {
		t.Errorf("condition context does not match the window: %#v", condition.Context)
	}
}

// A location_time licence with no window means the caller built its params wrong.
// Writing no flag at all (nobody can vote) is the only safe reading.
func TestLocationTimeWithoutWindowFailsClosed(t *testing.T) {
	change := EventVoteLicense(objectID, VoteLicenseLocationTime, nil)

	if len(change.Writes) != 0 {
		t.Errorf("want no write without a window, got %#v", change.Writes)
	}
	if len(change.Deletes) != 3 {
		t.Errorf("want all three flags cleared, got %d", len(change.Deletes))
	}
}

func TestVoteWindowValidate(t *testing.T) {
	cases := []struct {
		name    string
		window  VoteWindow
		wantErr bool
	}{
		{"normal", VoteWindow{960, 1320, "Europe/Paris"}, false},
		{"crossing midnight", VoteWindow{1320, 120, "Europe/Paris"}, false},
		{"empty window", VoteWindow{600, 600, "Europe/Paris"}, false},
		{"start out of range", VoteWindow{1440, 600, "Europe/Paris"}, true},
		{"negative end", VoteWindow{600, -1, "Europe/Paris"}, true},
		{"no timezone", VoteWindow{600, 900, ""}, true},
	}

	for _, testCase := range cases {
		err := testCase.window.Validate()
		if (err != nil) != testCase.wantErr {
			t.Errorf("%s: Validate() error = %v, wantErr %v", testCase.name, err, testCase.wantErr)
		}
	}
}

// One user_blocks row, both directions: a one-way block is a mute.
func TestBlockIsSymmetric(t *testing.T) {
	change := Block(ownerID, memberID)

	if len(change.Writes) != 2 || len(change.Deletes) != 0 {
		t.Fatalf("want the block in both directions and nothing else, got %#v", change)
	}
	seen := map[string]bool{}
	for _, tuple := range change.Writes {
		if tuple.Relation != RelBlocked {
			t.Errorf("write of %q, want blocked", tuple.Relation)
		}
		seen[tuple.User+"->"+tuple.Object] = true
	}
	if !seen[UserRef(ownerID)+"->"+UserRef(memberID)] || !seen[UserRef(memberID)+"->"+UserRef(ownerID)] {
		t.Errorf("both directions must be written, got %#v", change.Writes)
	}
}

// Ordering in the outbox is per-object, so a change concerning a PAIR needs a key
// that is the same whichever user initiated it. Otherwise a block and an
// unblock can be ordered against different keys and applied out of order.
func TestPairChangesShareAStableObjectKey(t *testing.T) {
	if Block(ownerID, memberID).ObjectKey != Unblock(memberID, ownerID).ObjectKey {
		t.Error("block and unblock of the same pair must share an ObjectKey, or they can be reordered")
	}
}

// An image's audience is whatever it is attached to. The thumbnail inherits from
// the original rather than carrying its own, so the audience lives in one place.
func TestImageAttachments(t *testing.T) {
	avatar := relationsOf(NewImage(objectID, ownerID, AvatarAttachment(), OriginAvatarUpload).Writes)
	if _, ok := avatar[RelImagePublic]; !ok {
		t.Error("an avatar must be world-viewable")
	}
	if avatar[RelImageOwner].User != UserRef(ownerID) {
		t.Error("an image must name its owner")
	}

	cover := relationsOf(NewImage(objectID, ownerID, PlaylistCoverAttachment("playlist-6"), OriginPlaylistCover).Writes)
	tuple, ok := cover[RelPlaylistCover]
	if !ok {
		t.Fatal("a cover must be attached to its playlist, or a private playlist's cover is world-viewable")
	}
	if tuple.User != Object(TypePlaylist, "playlist-6") {
		t.Errorf("playlist_cover_of subject is %q, want the playlist object", tuple.User)
	}
	if _, ok := cover[RelImagePublic]; ok {
		t.Error("a cover must not be public; it inherits the playlist's audience")
	}

	variant := relationsOf(NewImage("thumb-7", ownerID, VariantAttachment(objectID), OriginAvatarUpload).Writes)
	if variant[RelOriginalImage].User != Object(TypeImage, objectID) {
		t.Error("a variant must point at its original to inherit its audience")
	}
	if len(variant) != 2 {
		t.Errorf("a variant carries only owner and original, got %#v", variant)
	}
}

// parent is load-bearing: can_view and can_vote on an entry are both `... from
// parent`, so an entry without it is invisible and unvotable to everyone,
// including the host.
func TestQueueEntryAlwaysHasItsParent(t *testing.T) {
	withSuggester := relationsOf(NewQueueEntry(objectID, eventObjID, memberID).Writes)
	if withSuggester[RelParent].User != Object(TypeEvent, eventObjID) {
		t.Error("a queue entry must name its event as parent")
	}
	if withSuggester[RelSuggester].User != UserRef(memberID) {
		t.Error("a suggested entry must name its suggester")
	}

	// suggested_by_id is nullable (ON DELETE SET NULL), so an entry outlives the
	// account that suggested it. It keeps its parent and loses only can_remove.
	anonymous := NewQueueEntry(objectID, eventObjID, "")
	if len(anonymous.Writes) != 1 || anonymous.Writes[0].Relation != RelParent {
		t.Errorf("an entry with no suggester must still have its parent, got %#v", anonymous.Writes)
	}
}
