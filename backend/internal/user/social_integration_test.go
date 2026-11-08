//go:build integration

// GetRelationship against a real Postgres: the state a profile page reads to
// pick its buttons. Run with `make docker-backend-test-integration`.
//
// Same rolled-back transaction as profile_integration_test.go (testQueries).
package user

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	db "example.com/music-app/db/sqlc"
)

func TestGetRelationshipReadsEachState(t *testing.T) {
	ctx := context.Background()
	queries := testQueries(t)

	stamp := time.Now().UnixNano()
	newUser := func(name string) int64 {
		t.Helper()
		created, err := queries.CreateUser(ctx, db.CreateUserParams{
			DisplayName: fmt.Sprintf("social-it-%s-%d", name, stamp),
			Email:       fmt.Sprintf("social-it-%s-%d@example.test", name, stamp),
		})
		if err != nil {
			t.Fatalf("create %s: %v", name, err)
		}
		return created.ID
	}
	me, other := newUser("me"), newUser("other")

	read := func(viewer, target int64) db.GetRelationshipRow {
		t.Helper()
		row, err := queries.GetRelationship(ctx, db.GetRelationshipParams{ViewerID: viewer, TargetID: target})
		if err != nil {
			t.Fatalf("GetRelationship: %v", err)
		}
		return row
	}

	if row := read(me, other); row != (db.GetRelationshipRow{}) {
		t.Errorf("strangers: got %+v, want all zero", row)
	}

	request, err := queries.CreateFriendRequest(ctx, db.CreateFriendRequestParams{RequesterID: me, AddresseeID: other})
	if err != nil {
		t.Fatalf("create request: %v", err)
	}
	if row := read(me, other); row.OutgoingRequestID != request.ID || row.IncomingRequestID != 0 {
		t.Errorf("requester's side: got %+v, want outgoing %d", row, request.ID)
	}
	if row := read(other, me); row.IncomingRequestID != request.ID || row.OutgoingRequestID != 0 {
		t.Errorf("addressee's side: got %+v, want incoming %d", row, request.ID)
	}

	if _, err := queries.AcceptFriendRequest(ctx, db.AcceptFriendRequestParams{ID: request.ID, AddresseeID: other}); err != nil {
		t.Fatalf("accept: %v", err)
	}
	if _, err := queries.CreateFriendship(ctx, db.CreateFriendshipParams{UserID: other, FriendID: me}); err != nil {
		t.Fatalf("friendship: %v", err)
	}
	if row := read(other, me); !row.Friends || row.IncomingRequestID != 0 {
		t.Errorf("after accept: got %+v, want friends and no pending request", row)
	}

	// RemoveFriend's half in Postgres.
	if err := queries.DeleteFriendship(ctx, db.DeleteFriendshipParams{UserID: me, OtherUserID: other}); err != nil {
		t.Fatalf("delete friendship: %v", err)
	}
	if row := read(me, other); row.Friends {
		t.Error("still friends after DeleteFriendship")
	}

	// A block is visible to the blocker only: the blocked user must not learn it.
	if err := queries.BlockUser(ctx, db.BlockUserParams{BlockerID: me, BlockedID: other}); err != nil {
		t.Fatalf("block: %v", err)
	}
	if row := read(me, other); !row.BlockedByViewer {
		t.Error("blocker's side: want blocked_by_viewer")
	}
	if row := read(other, me); row != (db.GetRelationshipRow{}) {
		t.Errorf("blocked user's side: got %+v, want nothing disclosed", row)
	}
}

func TestSearchUsersFindsByNameAndHidesBlocks(t *testing.T) {
	ctx := context.Background()
	queries := testQueries(t)

	// A tag unique to this run, so rows left by other tests never match.
	tag := fmt.Sprintf("srch%d", time.Now().UnixNano())
	newUser := func(name string) int64 {
		t.Helper()
		created, err := queries.CreateUser(ctx, db.CreateUserParams{
			DisplayName: name,
			Email:       fmt.Sprintf("%s@example.test", strings.ToLower(strings.ReplaceAll(name, "%", "pct"))),
		})
		if err != nil {
			t.Fatalf("create %s: %v", name, err)
		}
		return created.ID
	}
	me := newUser("Me-" + tag)
	newUser("x-" + tag + "-Anna")        // contains the tag
	newUser(tag + "-Zed")                // starts with it
	newUser(tag + "%-percent")           // has a literal %
	blocker := newUser(tag + "-Blocker") // blocks me
	blocked := newUser(tag + "-Blocked") // blocked by me

	if err := queries.BlockUser(ctx, db.BlockUserParams{BlockerID: blocker, BlockedID: me}); err != nil {
		t.Fatalf("block: %v", err)
	}
	if err := queries.BlockUser(ctx, db.BlockUserParams{BlockerID: me, BlockedID: blocked}); err != nil {
		t.Fatalf("block: %v", err)
	}

	search := func(text string, limit int32) []string {
		t.Helper()
		rows, err := queries.SearchUsers(ctx, db.SearchUsersParams{ViewerID: me, Pattern: likePattern(text), MaxResults: limit})
		if err != nil {
			t.Fatalf("SearchUsers(%q): %v", text, err)
		}
		names := make([]string, len(rows))
		for i, r := range rows {
			names[i] = r.DisplayName
		}
		return names
	}

	// Upper case on purpose: the match ignores case. Prefix matches first,
	// then alphabetical; the caller and both blocks are left out.
	got := search(strings.ToUpper(tag), 10)
	want := []string{tag + "%-percent", tag + "-Zed", "x-" + tag + "-Anna"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("search %q: got %v, want %v", tag, got, want)
	}

	if got := search(tag+"%", 10); fmt.Sprint(got) != fmt.Sprint([]string{tag + "%-percent"}) {
		t.Errorf("a typed %% is literal: got %v", got)
	}
	if got := search(tag, 2); len(got) != 2 {
		t.Errorf("limit 2: got %v", got)
	}
}

func TestFriendRequestListsNameTheOtherPerson(t *testing.T) {
	ctx := context.Background()
	queries := testQueries(t)

	stamp := time.Now().UnixNano()
	newUser := func(name string) (int64, string) {
		t.Helper()
		created, err := queries.CreateUser(ctx, db.CreateUserParams{
			DisplayName: fmt.Sprintf("req-it-%s-%d", name, stamp),
			Email:       fmt.Sprintf("req-it-%s-%d@example.test", name, stamp),
		})
		if err != nil {
			t.Fatalf("create %s: %v", name, err)
		}
		return created.ID, created.DisplayName
	}
	me, myName := newUser("me")
	other, otherName := newUser("other")
	if _, err := queries.CreateFriendRequest(ctx, db.CreateFriendRequestParams{RequesterID: me, AddresseeID: other}); err != nil {
		t.Fatalf("create request: %v", err)
	}

	outgoing, err := queries.ListOutgoingFriendRequests(ctx, me)
	if err != nil || len(outgoing) != 1 {
		t.Fatalf("outgoing: %v, %d rows", err, len(outgoing))
	}
	if outgoing[0].OtherDisplayName != otherName || !outgoing[0].OtherPublicID.Valid {
		t.Errorf("outgoing names %q, want the addressee %q", outgoing[0].OtherDisplayName, otherName)
	}

	incoming, err := queries.ListIncomingFriendRequests(ctx, other)
	if err != nil || len(incoming) != 1 {
		t.Fatalf("incoming: %v, %d rows", err, len(incoming))
	}
	if incoming[0].OtherDisplayName != myName {
		t.Errorf("incoming names %q, want the requester %q", incoming[0].OtherDisplayName, myName)
	}
}
