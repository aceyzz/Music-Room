package event

import (
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
)

func TestPreviewUsable(t *testing.T) {
	now := time.Unix(1_760_000_000, 0)
	link := func(s string) pgtype.Text { return pgtype.Text{String: s, Valid: true} }
	cases := []struct {
		name string
		url  pgtype.Text
		want bool
	}{
		{"none", pgtype.Text{}, false},
		{"empty", link(""), false},
		{"valid for 10 more minutes", link("https://cdn/x.mp3?hdnea=exp=1760000600~acl=/x"), true},
		{"expired", link("https://cdn/x.mp3?hdnea=exp=1759999000~acl=/x"), false},
		{"expires within the minute", link("https://cdn/x.mp3?hdnea=exp=1760000030~acl=/x"), false},
		{"no expiry in it", link("https://cdn/x.mp3"), true},
	}
	for _, c := range cases {
		if got := previewUsable(c.url, now); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}
