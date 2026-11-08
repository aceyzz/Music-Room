package oauth

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func newTestCallback(t *testing.T) http.Handler {
	t.Helper()
	h, err := NewCallbackHandler("musicroom://oauth")
	if err != nil {
		t.Fatalf("NewCallbackHandler: %v", err)
	}
	return h
}

func get(h http.Handler, target string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, target, nil))
	return rec
}

func TestCallbackForwardsCodeAndState(t *testing.T) {
	rec := get(newTestCallback(t), CallbackPath+"?code=abc%2F123&state=xyz&scope=email&authuser=0")

	if rec.Code != http.StatusFound {
		t.Fatalf("status = %d, want 302", rec.Code)
	}
	loc, err := url.Parse(rec.Header().Get("Location"))
	if err != nil {
		t.Fatalf("Location: %v", err)
	}
	if loc.Scheme != "musicroom" || loc.Host != "oauth" {
		t.Errorf("Location = %s, want musicroom://oauth?...", loc)
	}
	q := loc.Query()
	if q.Get("code") != "abc/123" || q.Get("state") != "xyz" {
		t.Errorf("query = %v, want code and state round-tripped", q)
	}
	// le reste du retour provider ne part pas vers l'app.
	if q.Has("scope") || q.Has("authuser") {
		t.Errorf("query = %v, extra provider params forwarded", q)
	}
	if rec.Header().Get("Cache-Control") != "no-store" {
		t.Errorf("Cache-Control = %q, want no-store", rec.Header().Get("Cache-Control"))
	}
}

func TestCallbackForwardsProviderError(t *testing.T) {
	rec := get(newTestCallback(t), CallbackPath+"?error=access_denied&error_description=User+denied&state=xyz")

	if rec.Code != http.StatusFound {
		t.Fatalf("status = %d, want 302", rec.Code)
	}
	q, _ := url.ParseQuery(strings.SplitN(rec.Header().Get("Location"), "?", 2)[1])
	if q.Get("error") != "access_denied" || q.Get("error_description") != "User denied" || q.Get("state") != "xyz" {
		t.Errorf("query = %v", q)
	}
}

func TestCallbackRejectsRequestsThatAreNotProviderReturns(t *testing.T) {
	h := newTestCallback(t)

	if rec := get(h, CallbackPath+"?state=xyz"); rec.Code != http.StatusBadRequest {
		t.Errorf("no code: status = %d, want 400", rec.Code)
	}
	if rec := get(h, CallbackPath+"?code="+strings.Repeat("a", maxParamLen+1)); rec.Code != http.StatusBadRequest {
		t.Errorf("oversized code: status = %d, want 400", rec.Code)
	}

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, CallbackPath+"?code=abc", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST: status = %d, want 405", rec.Code)
	}
}

func TestCallbackDestinationComesFromConfigOnly(t *testing.T) {
	// un parametre qui ressemblerait a une destination est ignore.
	rec := get(newTestCallback(t), CallbackPath+"?code=abc&redirect_uri=https://evil.example&next=https://evil.example")
	if loc := rec.Header().Get("Location"); !strings.HasPrefix(loc, "musicroom://oauth?") || strings.Contains(loc, "evil") {
		t.Errorf("Location = %q", loc)
	}
}

func TestNewCallbackHandlerRejectsABadTarget(t *testing.T) {
	for _, bad := range []string{"", "oauth", "://nope"} {
		if _, err := NewCallbackHandler(bad); err == nil {
			t.Errorf("NewCallbackHandler(%q) = nil error", bad)
		}
	}
}
