package authz

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

// The model file is the contract; these constants are a hand transcription of it.
// Hand transcriptions drift, and this one drifts silently: a relation name that
// no longer exists in the model still writes without error and simply never
// matches a Check. So the tests below read the real file.
const modelPath = "../../../authz/model.fga"

var (
	defineRe = regexp.MustCompile(`(?m)^\s*define\s+([a-z_][a-z0-9_]*)\s*:`)
	typeRe   = regexp.MustCompile(`(?m)^type\s+([a-z_][a-z0-9_]*)\s*$`)
)

func loadModel(t *testing.T) (types, relations map[string]bool) {
	t.Helper()

	source, err := os.ReadFile(filepath.Clean(modelPath))
	if err != nil {
		t.Fatalf("read %s: %v", modelPath, err)
	}

	types, relations = map[string]bool{}, map[string]bool{}
	for _, match := range typeRe.FindAllStringSubmatch(string(source), -1) {
		types[match[1]] = true
	}
	for _, match := range defineRe.FindAllStringSubmatch(string(source), -1) {
		relations[match[1]] = true
	}

	if len(types) == 0 || len(relations) == 0 {
		t.Fatalf("parsed nothing out of %s (%d types, %d relations) -- the regexes "+
			"have gone stale, which would make every assertion below vacuous",
			modelPath, len(types), len(relations))
	}
	return types, relations
}

func TestObjectTypesExistInModel(t *testing.T) {
	types, _ := loadModel(t)

	for _, objectType := range []ObjectType{
		TypeUser, TypePlaylist, TypeEvent, TypeQueueEntry, TypeDevice, TypeImage,
	} {
		if !types[string(objectType)] {
			t.Errorf("ObjectType %q is not declared in %s", objectType, modelPath)
		}
	}
}

func TestRelationConstantsExistInModel(t *testing.T) {
	_, relations := loadModel(t)

	for _, relation := range []Relation{
		RelAccountOwner, RelAnyone, RelBlocked,
		RelPlaylistOwner, RelPlaylistAdmin, RelPlaylistEditor, RelPlaylistViewer,
		RelPlaylistPublic, RelOpenEdit,
		RelEventHost, RelEventAdmin, RelEventEditor, RelEventViewer, RelEventPublic,
		RelOpenVote, RelInvitedVote, RelWindowVote,
		RelParent, RelSuggester,
		RelDeviceOwner,
		RelImageOwner, RelImagePublic, RelPlaylistCover, RelEventCover, RelOriginalImage,
	} {
		if !relations[string(relation)] {
			t.Errorf("Relation %q is not declared in %s", relation, modelPath)
		}
	}
}

func TestNewUserWritesAccountOwnerAndAnyone(t *testing.T) {
	// Both are direct relations in the model and both are easy to forget. Without
	// account_owner the user cannot edit their own profile; without anyone they
	// are invisible to everyone else. Neither failure points at this function.
	change := NewUser("u1")

	var hasOwner, hasAnyone bool
	for _, tuple := range change.Writes {
		switch {
		case tuple.Relation == RelAccountOwner && tuple.User == UserRef("u1") && tuple.Object == UserRef("u1"):
			hasOwner = true
		case tuple.Relation == RelAnyone && tuple.User == Everyone && tuple.Object == UserRef("u1"):
			hasAnyone = true
		}
	}
	if !hasOwner {
		t.Error("missing the account_owner self-tuple")
	}
	if !hasAnyone {
		t.Error("missing the anyone wildcard tuple")
	}

	if len(change.Writes) != 2 {
		t.Errorf("got %d writes, want the two structural tuples", len(change.Writes))
	}
	if len(change.Deletes) != 0 {
		t.Errorf("got %d deletes, want 0: nothing exists yet for a brand new user", len(change.Deletes))
	}
	if change.ObjectKey != UserRef("u1") {
		t.Errorf("ObjectKey = %q, want %q -- the worker orders by this", change.ObjectKey, UserRef("u1"))
	}
}
