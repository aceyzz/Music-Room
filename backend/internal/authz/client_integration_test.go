//go:build integration

// Tests that need a live OpenFGA. Run with `make docker-backend-test-integration`.
//
// They exist mainly for one reason: Apply's fallback path keys off a message
// string the server produces, and a string is only as good as the test that
// pins it. If OpenFGA rewords or fixes that error, isTupleConflict silently
// stops matching, every retry turns into a hard failure, and the outbox fills up
// with rows that will never drain. That failure is a long way from its cause, so
// it gets caught here instead.
package authz

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	openfga "github.com/openfga/go-sdk"
	"github.com/openfga/go-sdk/client"
)

func testClient(t *testing.T) (*Client, *client.OpenFgaClient) {
	t.Helper()

	apiURL := envOr("APP_OPENFGA_API_URL", "http://localhost:8082")
	storeID := envOr("APP_OPENFGA_STORE_ID", "01MRAVTHZ00000000000000000")

	authzClient, err := NewClient(Config{APIURL: apiURL, StoreID: storeID})
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	if _, err := authzClient.Ping(context.Background()); err != nil {
		t.Fatalf("OpenFGA not usable at %s (store %s): %v", apiURL, storeID, err)
	}

	raw, err := client.NewSdkClient(&client.ClientConfiguration{ApiUrl: apiURL, StoreId: storeID})
	if err != nil {
		t.Fatalf("raw sdk client: %v", err)
	}
	return authzClient, raw
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

// uniqueUser keeps parallel runs and reruns from colliding on the same object.
func uniqueUser(t *testing.T) string {
	t.Helper()
	return fmt.Sprintf("t%d%s", time.Now().UnixNano(), t.Name()[:4])
}

func check(t *testing.T, raw *client.OpenFgaClient, user, relation, object string) bool {
	t.Helper()

	// HIGHER_CONSISTENCY skips the server's check cache: a test that checks,
	// writes, then checks again must see its own write.
	response, err := raw.Check(context.Background()).Body(client.ClientCheckRequest{
		User: user, Relation: relation, Object: object,
	}).Options(client.ClientCheckOptions{
		Consistency: openfga.CONSISTENCYPREFERENCE_HIGHER_CONSISTENCY.Ptr(),
	}).Execute()
	if err != nil {
		t.Fatalf("check %s#%s@%s: %v", object, relation, user, err)
	}
	return response.GetAllowed()
}

// cleanup removes whatever a test wrote, so the dev store does not accumulate
// junk that later confuses a manual `fga query check`.
func cleanup(t *testing.T, authzClient *Client, tuples ...Tuple) {
	t.Helper()
	t.Cleanup(func() {
		// Deletes only, and tolerant: some of these may never have been written.
		_ = authzClient.applyOneByOne(context.Background(), Change{Deletes: tuples})
	})
}

// The core claim: applying the same change twice is not an error. Everything
// upstream -- the inline retry, the worker, the lease expiring mid-delivery --
// depends on this being true.
func TestApplyIsIdempotent(t *testing.T) {
	authzClient, raw := testClient(t)
	userID := uniqueUser(t)
	object := UserRef(userID)

	change := NewUser(userID)
	cleanup(t, authzClient, change.Writes...)

	ctx := context.Background()
	if err := authzClient.Apply(ctx, change); err != nil {
		t.Fatalf("first Apply: %v", err)
	}
	if err := authzClient.Apply(ctx, change); err != nil {
		t.Fatalf("second Apply of the identical change must be a no-op, got: %v", err)
	}

	if !check(t, raw, object, "can_edit_profile", object) {
		t.Error("account_owner did not take effect: the user cannot edit their own profile")
	}
	if !check(t, raw, UserRef("stranger"), "can_view_profile", object) {
		t.Error("anyone did not take effect: the profile is invisible to a stranger")
	}
}

// This is the one that pins the message string.
//
// A batch containing one tuple that already exists is rejected WHOLE by the
// server -- the valid tuples in it do not land. Apply is supposed to notice and
// re-apply one at a time. If the marker stops matching, the second Apply below
// returns an error and the new tuple is missing; both assertions catch it.
func TestConflictsAreTolerated(t *testing.T) {
	authzClient, raw := testClient(t)
	userID := uniqueUser(t)
	object := UserRef(userID)

	owner := Tuple{User: object, Relation: RelAccountOwner, Object: object}
	anyone := Tuple{User: Everyone, Relation: RelAnyone, Object: object}
	cleanup(t, authzClient, owner, anyone)

	ctx := context.Background()
	if err := authzClient.Apply(ctx, Change{Writes: []Tuple{owner}}); err != nil {
		t.Fatalf("seed write: %v", err)
	}

	// owner is now a duplicate; anyone is new. A plain batch fails outright.
	if err := authzClient.applyBatch(ctx, Change{Writes: []Tuple{owner, anyone}}); err == nil {
		t.Log("note: this server now accepts duplicate writes in a batch; the " +
			"fallback in Apply has become redundant rather than wrong")
	} else if !isTupleConflict(err) {
		t.Fatalf("a duplicate write no longer produces a recognised conflict.\n"+
			"isTupleConflict is matching on %q, which is no longer in:\n%v",
			conflictMarker, err)
	}

	// Apply must absorb that and still get the new tuple in.
	if err := authzClient.Apply(ctx, Change{Writes: []Tuple{owner, anyone}}); err != nil {
		t.Fatalf("Apply over a partially-applied change: %v", err)
	}
	if !check(t, raw, UserRef("stranger"), "can_view_profile", object) {
		t.Error("the new tuple in the conflicting batch never landed")
	}
}

// Deleting something that is not there must also be tolerated: a retry after an
// ambiguous delete looks exactly like this.
func TestDeletingAbsentTupleIsTolerated(t *testing.T) {
	authzClient, _ := testClient(t)
	object := UserRef(uniqueUser(t))

	err := authzClient.Apply(context.Background(), Change{
		Deletes: []Tuple{{User: Everyone, Relation: RelAnyone, Object: object}},
	})
	if err != nil {
		t.Fatalf("deleting an absent tuple must be a no-op, got: %v", err)
	}
}

// A block must close the profile to the blocked user, and an unblock open it
// again: a write, then a delete, each reaching the computed relation.
func TestBlockClosesAndUnblockReopensTheProfile(t *testing.T) {
	authzClient, raw := testClient(t)
	userID, otherID := uniqueUser(t), uniqueUser(t)+"b"
	object, other := UserRef(userID), UserRef(otherID)

	ctx := context.Background()
	account := NewUser(userID)
	block := Block(userID, otherID)
	cleanup(t, authzClient, append(account.Writes, block.Writes...)...)

	if err := authzClient.Apply(ctx, account); err != nil {
		t.Fatalf("new user: %v", err)
	}
	if !check(t, raw, other, "can_view_profile", object) {
		t.Fatal("precondition failed: a profile should be visible to anyone")
	}
	if err := authzClient.Apply(ctx, block); err != nil {
		t.Fatalf("block: %v", err)
	}
	if check(t, raw, other, "can_view_profile", object) {
		t.Error("the profile is still visible to the user it blocked")
	}
	if err := authzClient.Apply(ctx, Unblock(userID, otherID)); err != nil {
		t.Fatalf("unblock: %v", err)
	}
	if !check(t, raw, other, "can_view_profile", object) {
		t.Error("the profile stayed closed after the unblock")
	}
}
