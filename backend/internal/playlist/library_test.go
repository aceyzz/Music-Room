package playlist

import (
	"testing"

	db "example.com/music-app/db/sqlc"
)

func TestLibraryRelation(t *testing.T) {
	public, private := db.ResourceVisibilityPublic, db.ResourceVisibilityPrivate
	cases := []struct {
		name string
		row  db.ListLibraryPlaylistsRow
		want string
	}{
		{"own, even a friend's member list", db.ListLibraryPlaylistsRow{IsOwner: true, IsMember: true, OwnerIsFriend: false}, "mine"},
		{"invited", db.ListLibraryPlaylistsRow{IsMember: true, OwnerIsFriend: true, Visibility: private}, "shared"},
		{"a friend's public one", db.ListLibraryPlaylistsRow{OwnerIsFriend: true, Visibility: public}, "friend"},
		{"a stranger's public one: not in the library", db.ListLibraryPlaylistsRow{Visibility: public}, ""},
		{"a friend's private one, not a member", db.ListLibraryPlaylistsRow{OwnerIsFriend: true, Visibility: private}, ""},
	}
	for _, c := range cases {
		if got := libraryRelation(c.row); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}
