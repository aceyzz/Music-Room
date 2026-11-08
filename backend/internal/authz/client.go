package authz

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"

	openfga "github.com/openfga/go-sdk"
	"github.com/openfga/go-sdk/client"
)

// Config points the client at a store. ModelID is optional: left empty, Ping
// pins whatever model is latest at boot.
//
// Pinned one way or the other, never resolved per call: a request without a
// model id makes OpenFGA look up the latest model on every Check, a cost paid
// on the hottest path of the backend for a value that changes only on
// `make fga-model`. Leaving ModelID empty is right for development, where that
// command appends a new immutable model version on every push (and restarts
// the backend so it pins the new one); setting it is right for production,
// where the model a service was tested against should not change under it.
// The resolved id is logged at boot so the value to pin is always visible.
type Config struct {
	APIURL  string
	StoreID string
	ModelID string
}

// Client talks to OpenFGA: Apply writes tuple changes (this file), Check asks
// questions (check.go).
//
// The two halves share a connection and nothing else. They have opposite
// failure policies -- a failed write must be retried until it lands, because a
// missing tuple is invisible; a failed check must answer now, and the only safe
// answer is a denial -- so neither retries on the other's behalf and the retry
// machinery (internal/authz/outbox) wraps Apply alone.
//
// The SDK has its own idea of both, and NewClient overrides it: by default it
// retries three times on 429/5xx/network errors, and it uses
// http.DefaultClient, which keeps two idle connections per host. Under load
// those two compound -- an overloaded OpenFGA gets each Check up to four
// times, each on a fresh TCP connection -- the likeliest reading of the backlog
// that never drained in the first load tests (docs/load-testing.md).
type Client struct {
	fga *client.OpenFgaClient
}

// maxIdleConns bounds the keep-alive pool to OpenFGA. Every request goes to
// that one host, so the per-host cap is the one that matters: sized above the
// concurrent Checks a single backend sees at its knee, so a burst reuses
// connections instead of opening and tearing down one per Check.
const maxIdleConns = 256

func NewClient(cfg Config) (*Client, error) {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.MaxIdleConns = maxIdleConns
	transport.MaxIdleConnsPerHost = maxIdleConns

	sdkConfig := &client.ClientConfiguration{
		ApiUrl:  cfg.APIURL,
		StoreId: cfg.StoreID,
		// No client-level timeout, as with http.DefaultClient before it: the
		// request path bounds its calls by context (the interceptor's check
		// timeout).
		HTTPClient: &http.Client{Transport: transport},
		// No SDK retries, for either half -- see Client. MinWaitInMs is unused
		// with zero retries but must be positive to pass the SDK's validation.
		RetryParams: &openfga.RetryParams{MaxRetry: 0, MinWaitInMs: 100},
	}
	if cfg.ModelID != "" {
		sdkConfig.AuthorizationModelId = cfg.ModelID
	}

	fga, err := client.NewSdkClient(sdkConfig)
	if err != nil {
		return nil, fmt.Errorf("openfga client: %w", err)
	}
	return &Client{fga: fga}, nil
}

// Ping verifies the store is reachable AND has an authorization model, and pins
// that model when Config.ModelID was left empty (see Config).
//
// Both halves matter. The store is created by `fga store import --store-id`,
// which writes a model at a fixed id without creating a stores row -- so an
// unreachable server and an empty store fail in different places, and a store
// that exists with no model answers every Check with a confusing error rather
// than a denial. Called at boot so neither is discovered at the first write.
func (c *Client) Ping(ctx context.Context) (modelID string, err error) {
	response, err := c.fga.ReadLatestAuthorizationModel(ctx).Execute()
	if err != nil {
		return "", fmt.Errorf("openfga unreachable or store missing: %w", err)
	}
	if response.AuthorizationModel == nil {
		return "", errors.New("openfga store has no authorization model: run `make fga-model`")
	}
	latest := response.AuthorizationModel.Id

	pinned, err := c.fga.GetAuthorizationModelId()
	if err != nil {
		return "", fmt.Errorf("openfga client model id: %w", err)
	}
	if pinned == "" {
		if err := c.fga.SetAuthorizationModelId(latest); err != nil {
			return "", fmt.Errorf("openfga pin model %s: %w", latest, err)
		}
		return latest, nil
	}
	if pinned != latest {
		// Legitimate (a pinned production model, a newer one pushed for the next
		// release) but worth a line: it is the first thing to rule out when a
		// Check answers differently than authz/model.fga suggests.
		log.Printf("openfga: using pinned model %s; the store's latest is %s", pinned, latest)
	}
	return pinned, nil
}

// Apply makes one logical change take effect. It is idempotent: applying the
// same Change twice is not an error, which is the property the whole retry chain
// above it depends on.
//
// Two paths, for a reason worth understanding before touching this.
//
// The fast path sends writes and deletes as ONE transactional batch, so they land
// together. That matters where a delete and a write are only correct as a pair --
// profile visibility passes through a fail-open state if the write lands first
// (see the Change doc comment).
//
// But OpenFGA rejects a batch containing a tuple that already exists, or a delete
// of one that does not, and it rejects the WHOLE batch: nothing applies, including
// the tuples that were perfectly valid. Verified against server v1.18.3. The SDK
// offers on_duplicate_writes / on_missing_deletes options for exactly this, and
// that server silently ignores them -- so they are not used here; this fallback
// is the mechanism, and it works on any server version.
//
// So on that specific class of error, and only that class, Apply re-applies the
// change one tuple at a time, treating "already exists" and "does not exist" as
// success. Deletes go first, which is what makes the intermediate state safe:
// having removed a flag but not yet added its replacement reads as private, while
// the reverse order reads as public. Partial progress is fine because the outbox
// row survives until every tuple has landed.
func (c *Client) Apply(ctx context.Context, change Change) error {
	if change.IsEmpty() {
		return nil
	}

	err := c.applyBatch(ctx, change)
	if err == nil || !isTupleConflict(err) {
		return err
	}
	return c.applyOneByOne(ctx, change)
}

func (c *Client) applyBatch(ctx context.Context, change Change) error {
	body := client.ClientWriteRequest{}
	for _, tuple := range change.Writes {
		body.Writes = append(body.Writes, toSDKTuple(tuple))
	}
	for _, tuple := range change.Deletes {
		body.Deletes = append(body.Deletes, toSDKTupleWithoutCondition(tuple))
	}

	if _, err := c.fga.Write(ctx).Body(body).Execute(); err != nil {
		return fmt.Errorf("openfga write: %w", err)
	}
	return nil
}

// applyOneByOne is the reconciliation path. Deletes first -- see Apply.
func (c *Client) applyOneByOne(ctx context.Context, change Change) error {
	for _, tuple := range change.Deletes {
		body := client.ClientWriteRequest{
			Deletes: []client.ClientTupleKeyWithoutCondition{toSDKTupleWithoutCondition(tuple)},
		}
		if err := c.writeTolerantly(ctx, body); err != nil {
			return fmt.Errorf("delete %s: %w", describe(tuple), err)
		}
	}
	for _, tuple := range change.Writes {
		body := client.ClientWriteRequest{
			Writes: []client.ClientTupleKey{toSDKTuple(tuple)},
		}
		if err := c.writeTolerantly(ctx, body); err != nil {
			return fmt.Errorf("write %s: %w", describe(tuple), err)
		}
	}
	return nil
}

// writeTolerantly issues a single-tuple write and swallows the conflict error.
//
// With one tuple in the request, a conflict can only mean "the tuple is already
// in the state we wanted" -- a duplicate write or a delete of something already
// gone. Both are the desired end state, reached by someone else or by an earlier
// attempt of ours whose response we never saw. That last case is the whole reason
// this exists: a write that succeeds and then fails to report back is
// indistinguishable, from here, from one that never happened.
func (c *Client) writeTolerantly(ctx context.Context, body client.ClientWriteRequest) error {
	_, err := c.fga.Write(ctx).Body(body).Execute()
	if err == nil || isTupleConflict(err) {
		return nil
	}
	return err
}

// conflictMarker is the sentence OpenFGA appends to both "cannot write a tuple
// which already exists" and "cannot delete a tuple which does not exist".
//
// Matching on message text is unpleasant, and it is done here because the
// alternative is worse: the error code for these is
// write_failed_due_to_invalid_input, which the server also returns for genuinely
// bad input like an unknown relation. Treating those as benign would make a
// real bug look like a successful sync.
//
// Verified against server v1.18.3. TestConflictsAreTolerated in the integration
// tests pins it, so a server upgrade that reworded this fails the build rather
// than quietly turning every retry into a hard error.
const conflictMarker = "tuple to be written already existed or the tuple to be deleted did not exist"

func isTupleConflict(err error) bool {
	if err == nil {
		return false
	}
	if strings.Contains(err.Error(), conflictMarker) {
		return true
	}

	// The SDK's typed API errors keep the response body separate from the
	// message, so check it too rather than depend on which one carries the text.
	var withBody interface{ Body() []byte }
	if errors.As(err, &withBody) {
		return strings.Contains(string(withBody.Body()), conflictMarker)
	}
	return false
}

func toSDKTuple(tuple Tuple) client.ClientTupleKey {
	key := client.ClientTupleKey{
		User:     tuple.User,
		Relation: string(tuple.Relation),
		Object:   tuple.Object,
	}
	if tuple.Condition != nil {
		context := tuple.Condition.Context
		key.Condition = &openfga.RelationshipCondition{
			Name:    tuple.Condition.Name,
			Context: &context,
		}
	}
	return key
}

// Deletes carry no condition: a tuple is identified by its three parts, and
// OpenFGA's delete API takes the key only.
func toSDKTupleWithoutCondition(tuple Tuple) client.ClientTupleKeyWithoutCondition {
	return client.ClientTupleKeyWithoutCondition{
		User:     tuple.User,
		Relation: string(tuple.Relation),
		Object:   tuple.Object,
	}
}

func describe(tuple Tuple) string {
	return fmt.Sprintf("%s#%s@%s", tuple.Object, tuple.Relation, tuple.User)
}
