package main

import (
	"strings"
	"testing"
	"time"
)

// The rules the database and the Go handlers rely on, checked on the world
// before it ever reaches Postgres: a violation here would otherwise surface as
// a constraint error halfway through the seed, or worse, as a state the app
// could never have produced.

func TestWorldKeepsTheDatabaseRules(t *testing.T) {
	w := Build(time.Now())

	t.Run("accounts", func(t *testing.T) {
		emails, names := map[string]bool{}, map[string]bool{}
		for _, u := range w.Users {
			e, n := strings.ToLower(u.Email), strings.ToLower(u.DisplayName)
			if emails[e] || names[n] {
				t.Errorf("duplicate account %q / %q", u.Email, u.DisplayName)
			}
			emails[e], names[n] = true, true
			if c := u.Profile.Country; c != "" && (len(c) != 2 || strings.ToUpper(c) != c) {
				t.Errorf("%s: country %q is not an ISO code", u.Email, c)
			}
			for _, scope := range u.Profile.Visibility {
				if scope != "public" && scope != "friends" && scope != "private" {
					t.Errorf("%s: visibility %q", u.Email, scope)
				}
			}
		}
		if len(w.Users) != 122 {
			t.Errorf("%d accounts, want 122", len(w.Users))
		}
	})

	t.Run("social graph", func(t *testing.T) {
		friends, pending, blocked := map[pairKey]bool{}, map[pairKey]bool{}, map[pairKey]bool{}
		for _, f := range w.Friendships {
			k := pair(f.A, f.B)
			if f.A == f.B || friends[k] {
				t.Errorf("bad friendship %v", k)
			}
			friends[k] = true
		}
		for _, r := range w.FriendRequests {
			if r.From == r.To {
				t.Errorf("request to self")
			}
			if r.Status == "pending" {
				k := pair(r.From, r.To)
				if pending[k] || friends[k] {
					t.Errorf("second open request or request between friends: %v", k)
				}
				pending[k] = true
			}
		}
		for _, b := range w.Blocks {
			k := pair(b.Blocker, b.Blocked)
			if friends[k] || pending[k] {
				t.Errorf("block over a live relation: %v", k)
			}
			blocked[k] = true
		}
		shown := 0
		for _, f := range w.friendsOf(uAlex) {
			if w.active(f) {
				shown++
			}
		}
		if shown != 26 {
			t.Errorf("Alex shows %d friends, want 26", shown)
		}
	})

	t.Run("playlists", func(t *testing.T) {
		for _, p := range w.Playlists {
			for i, op := range p.Ops {
				if op.Revision != i+1 {
					t.Errorf("%s: revision %d at op %d", p.Name, op.Revision, i)
				}
				if i > 0 && op.At.Before(p.Ops[i-1].At) {
					t.Errorf("%s: op %d goes back in time", p.Name, op.Revision)
				}
			}
			// Replaying the ops gives the rows that are there, in order.
			var replay []*PlaylistRow
			for _, op := range p.Ops {
				switch op.Type {
				case "add_song":
					replay = append(replay, op.Row)
				case "remove_song":
					for i, r := range replay {
						if r == op.Row {
							replay = append(replay[:i:i], replay[i+1:]...)
							break
						}
					}
				}
			}
			if len(replay) != len(p.Rows) {
				t.Errorf("%s: ops leave %d rows, playlist has %d", p.Name, len(replay), len(p.Rows))
			}
			for i := 1; i < len(p.Rows); i++ {
				if p.Rows[i].Position.Cmp(p.Rows[i-1].Position) <= 0 {
					t.Errorf("%s: positions not strictly increasing at %d", p.Name, i)
				}
			}
			roles := map[int]bool{}
			for _, m := range p.Members {
				if roles[m.User] {
					t.Errorf("%s: member twice", p.Name)
				}
				roles[m.User] = true
			}
			open := map[int]bool{}
			for _, inv := range p.Invitations {
				if inv.Status == "pending" {
					if open[inv.Invitee] || roles[inv.Invitee] {
						t.Errorf("%s: pending invitation to a member or twice", p.Name)
					}
					open[inv.Invitee] = true
				}
				if inv.Status == "accepted" && !roles[inv.Invitee] {
					t.Errorf("%s: accepted invitation but not a member", p.Name)
				}
				if inv.CreatedAt.Before(p.CreatedAt) {
					t.Errorf("%s: invitation before the playlist existed", p.Name)
				}
			}
		}
		if len(w.Playlists) != 48 {
			t.Errorf("%d playlists, want 48", len(w.Playlists))
		}
	})

	t.Run("events", func(t *testing.T) {
		hosted := 0
		for _, e := range w.Events {
			if e.Host == uAlex {
				hosted++
			}
			if e.StartsAt == nil || e.EndsAt == nil {
				t.Errorf("%s: no dates (CreateEvent requires them)", e.Name)
			} else if !e.EndsAt.After(*e.StartsAt) {
				t.Errorf("%s: ends before it starts", e.Name)
			}
			if (e.License == "location_time") != (e.Venue != nil) {
				t.Errorf("%s: location_time needs a venue, and only it", e.Name)
			}
			active := map[int]bool{}
			playing := 0
			for _, q := range e.Entries {
				if q.Status == "queued" || q.Status == "playing" {
					if active[q.Song] {
						t.Errorf("%s: song %d twice in the live queue", e.Name, q.Song)
					}
					active[q.Song] = true
				}
				if q.Status == "playing" {
					playing++
				}
				if (q.Status == "played" || q.Status == "skipped") != (q.PlayedAt != nil) {
					t.Errorf("%s: played_at and status disagree", e.Name)
				}
				voters := map[int]bool{}
				for _, v := range q.Votes {
					if voters[v.User] {
						t.Errorf("%s: two votes by one user on one entry", e.Name)
					}
					voters[v.User] = true
					if v.At.After(w.Now) || (q.PlayedAt != nil && v.At.After(*q.PlayedAt)) || v.At.Before(q.CreatedAt) {
						t.Errorf("%s: vote outside the entry's queued time", e.Name)
					}
				}
			}
			if playing > 1 {
				t.Errorf("%s: %d entries playing", e.Name, playing)
			}
			if pb := e.Playback; pb.Current != nil && pb.Current.Status != "playing" {
				t.Errorf("%s: current entry is %s", e.Name, pb.Current.Status)
			}
			members := map[int]bool{}
			for _, m := range e.Members {
				members[m.User] = true
			}
			for _, inv := range e.Invitations {
				if inv.Status == "accepted" && !members[inv.Invitee] {
					t.Errorf("%s: accepted invitation but not a member", e.Name)
				}
				if inv.Status == "pending" && members[inv.Invitee] {
					t.Errorf("%s: pending invitation to a member", e.Name)
				}
			}
		}
		if len(w.Events) != 40 || hosted != 18 {
			t.Errorf("%d events (%d by Alex), want 40 (18)", len(w.Events), hosted)
		}
	})

	t.Run("control grants", func(t *testing.T) {
		live := map[[3]int]bool{}
		for _, g := range w.Grants {
			owner := w.Devices[g.Device].Owner
			if !w.areFriends(owner, g.Grantee) {
				t.Errorf("grant on %s to a non-friend", w.Devices[g.Device].Name)
			}
			if g.RevokedAt == nil {
				k := [3]int{g.Device, g.Grantee, g.Event}
				if live[k] {
					t.Errorf("two live grants for %v", k)
				}
				live[k] = true
			}
		}
	})

	t.Run("no account is locked out", func(t *testing.T) {
		for _, a := range w.LoginAttempts {
			if !a.Succeeded && a.At.After(w.ago(15*time.Minute)) {
				t.Errorf("recent failure for %s", a.Email)
			}
		}
	})
}

func TestWorldDoesNotDependOnTheClock(t *testing.T) {
	a := renderDoc(Build(docNow))
	b := renderDoc(Build(docNow.Add(1234 * time.Hour)))
	if a != b {
		t.Fatal("the world's shape changes with the time of seeding")
	}
}

func TestPositionsPrintExactly(t *testing.T) {
	w := Build(docNow)
	for _, p := range w.Playlists {
		for _, r := range p.Rows {
			if s := decimal(r.Position); strings.Contains(s, "e") || s == "" {
				t.Fatalf("%s: position %q", p.Name, s)
			}
		}
	}
}
