package main

import (
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
	"time"
)

// The load-test population (V.7, docs/annex/load-testing.md): a second world, next to
// the demo one, sized by -loadtest N and written by the same code (writeWorld),
// so its rows and permission tuples are exactly what the demo world's are.
//
// What k6 needs from it, and why it is seeded rather than made through the API:
//
//   - A session per user with a KNOWN token (LoadSessionToken). Logging in costs
//     an Argon2id hash at 64 MiB (internal/security/password.go); a thousand
//     virtual users signing in at the start of a run would measure the hash, not
//     the services, and need ~64 GB of RAM at once. Login gets its own scenario
//     (loadtest/scenarios/login.js) instead. The password is still set, the same
//     one as the demo world's, so that scenario can use these accounts.
//   - Groups already formed: an event, a playlist and a delegation circle per
//     user, members and grants included. Forming them through the API would
//     each time wait on the outbox (tuples are asynchronous), which is the
//     pytest suite's business, not the load test's.
//   - Songs only from the seeded catalogue, which is already in `songs`:
//     SuggestSong and AddSongToPlaylist then never call Deezer, so no request
//     under load leaves the machine.
//
// Every user takes part in all three services -- one event, one playlist, one
// delegation circle -- so any scenario can use any virtual user: k6's VU n is
// user n-1, whatever it does.
//
// Public ids use their own prefix (10ad = "load") so a load-test row is never
// mistaken for a demo one in a log line, and the two worlds cannot collide.

// LoadConfig sizes the load world. Group sizes are what one person meets in
// each service: an event crowd, a small group of co-editors, a few friends
// sharing a speaker.
type LoadConfig struct {
	Users          int `json:"users"`
	EventSize      int `json:"eventSize"`      // members per event, host included
	PlaylistSize   int `json:"playlistSize"`   // members per playlist, owner included
	DelegationSize int `json:"delegationSize"` // per circle: the device owner, the delegates, and one friend left without a grant
	QueueLength    int `json:"queueLength"`    // queued entries per event at the start
	PlaylistSongs  int `json:"playlistSongs"`  // songs per playlist at the start
}

var defaultLoadConfig = LoadConfig{
	Users: 1000, EventSize: 50, PlaylistSize: 10, DelegationSize: 6,
	QueueLength: 30, PlaylistSongs: 20,
}

// LoadSessionToken is user n's session token (n from 1). Only its SHA-256 is
// stored, as for every session.
func LoadSessionToken(n int) string { return fmt.Sprintf("lt-session-%06d", n) }

func loadPublicID(kind, n int) string {
	return fmt.Sprintf("10ad%04x-0000-4000-8000-%012x", kind, n)
}

// DemoEventName is the live demo event the bots of `make loadtest-demo` vote in,
// while Alex watches it on the phone. Public with an "everyone" licence, so
// anyone signed in may vote there without being a member.
const DemoEventName = "Friday Warm-up — Live"

// LoadFixtures is what loadtest/lib/fixtures.js reads. Users are referred to by
// their index in Users.
type LoadFixtures struct {
	GeneratedAt time.Time      `json:"generatedAt"`
	Config      LoadConfig     `json:"config"`
	Users       []LoadUser     `json:"users"`
	Events      []LoadEvent    `json:"events"`
	Playlists   []LoadPlaylist `json:"playlists"`
	Circles     []LoadCircle   `json:"circles"`
	// Deezer ids of the catalogue: what SuggestSong and AddSongToPlaylist take.
	Songs     []int64 `json:"songs"`
	DemoEvent string  `json:"demoEvent,omitempty"`
}

type LoadUser struct {
	PublicID string `json:"publicId"`
	Email    string `json:"email"`
	Token    string `json:"token"`
	Event    int    `json:"event"`
	Playlist int    `json:"playlist"`
	Circle   int    `json:"circle"`
}

type LoadEvent struct {
	PublicID string `json:"publicId"`
	Host     int    `json:"host"`
	Members  []int  `json:"members"`
}

type LoadPlaylist struct {
	PublicID string `json:"publicId"`
	Owner    int    `json:"owner"`
	Members  []int  `json:"members"`
}

type LoadCircle struct {
	Owner  int    `json:"owner"`
	Device string `json:"device"` // public id
	// The circle's own live event, hosted by the owner, where the delegates
	// drive playback with the owner's device.
	Event     string `json:"event"`
	Delegates []int  `json:"delegates"` // hold a grant on Device for Event
	// A friend of the owner without a grant: the one the owner grants and
	// revokes in a loop (delegation.js), so grants churn without ever
	// conflicting with the delegates' ones.
	Spare int `json:"spare"`
}

// BuildLoad assembles the load world. Deterministic for a given now and config,
// like Build.
func BuildLoad(now time.Time, cfg LoadConfig, demo *World) (*World, *LoadFixtures) {
	w := &World{Now: now, rng: rand.New(rand.NewPCG(4242, 2026))}
	w.buildSongs()
	fx := &LoadFixtures{GeneratedAt: now, Config: cfg}
	for _, s := range w.Songs {
		fx.Songs = append(fx.Songs, s.DeezerID)
	}
	if demo != nil {
		for _, e := range demo.Events {
			if e.Name == DemoEventName {
				fx.DemoEvent = e.PublicID
			}
		}
	}

	created := w.ago(30 * day)
	for i := 0; i < cfg.Users; i++ {
		n := i + 1
		u := &User{
			Idx: i, PublicID: loadPublicID(kindUser, n),
			Email: fmt.Sprintf("lt-%06d@%s", n, EmailDomain), DisplayName: fmt.Sprintf("Load %06d", n),
			HasPassword: true, Status: "active", Verified: true, CreatedAt: created,
			Profile: Profile{Visibility: visDefault},
		}
		w.Users = append(w.Users, u)
		w.Sessions = append(w.Sessions, &Session{
			PublicID: loadPublicID(kindSession, n), User: i, Device: -1, Token: LoadSessionToken(n),
			UserAgent: "k6 (music-room load test)", IP: "127.0.0.1",
			CreatedAt: w.ago(minute), LastUsed: w.ago(minute), ExpiresAt: w.in(30 * day),
		})
		fx.Users = append(fx.Users, LoadUser{PublicID: u.PublicID, Email: u.Email, Token: LoadSessionToken(n)})
	}

	// groups splits the users into consecutive groups of `size`; the last one
	// takes the remainder (so it is never smaller than 2 unless N is).
	groups := func(size int) [][]int {
		var out [][]int
		for start := 0; start < cfg.Users; start += size {
			end := min(start+size, cfg.Users)
			g := make([]int, 0, end-start)
			for u := start; u < end; u++ {
				g = append(g, u)
			}
			if len(g) < 2 && len(out) > 0 {
				out[len(out)-1] = append(out[len(out)-1], g...)
				continue
			}
			out = append(out, g)
		}
		return out
	}
	songs := w.allSongs()

	// --- events: live, public, "everyone" may vote, a song playing ----------
	liveEvent := func(host int, name string, members []int) *Event {
		e := &Event{
			Idx: len(w.Events), PublicID: loadPublicID(kindEvent, len(w.Events)+1),
			Host: host, Name: name, Description: "Load test", Visibility: "public", License: "everyone",
			Status: "live", StartsAt: ptr(w.ago(hour)), EndsAt: ptr(w.in(30 * day)),
			SourcePlaylist: -1, CreatedAt: w.ago(day),
		}
		for _, m := range members {
			role := "viewer"
			if m == host {
				role = "owner"
			}
			e.Members = append(e.Members, Member{User: m, Role: role, InvitedBy: host, Joined: e.CreatedAt})
		}
		e.Members[0].InvitedBy = -1
		picked := pick(w, songs, cfg.QueueLength+1)
		for i, song := range picked {
			q := &QueueEntry{
				Idx: w.entriesCreated, PublicID: loadPublicID(kindQueueEntry, w.entriesCreated+1),
				Song: song, SuggestedBy: members[i%len(members)], Status: "queued",
				CreatedAt: w.ago(time.Duration(len(picked)-i) * minute),
			}
			if i == 0 {
				q.Status = "playing"
			}
			w.entriesCreated++
			e.Entries = append(e.Entries, q)
		}
		started := w.ago(10 * time.Second)
		e.Playback = Playback{Current: e.Entries[0], ControllerUser: host, ControllerDevice: -1,
			StartedAt: &started, UpdatedAt: started}
		w.Events = append(w.Events, e)
		return e
	}
	for gi, g := range groups(cfg.EventSize) {
		e := liveEvent(g[0], fmt.Sprintf("Load Event %04d", gi+1), g)
		fx.Events = append(fx.Events, LoadEvent{PublicID: e.PublicID, Host: g[0], Members: g})
		for _, u := range g {
			fx.Users[u].Event = gi
		}
	}

	// --- playlists: members only, the owner and editors ------------------------
	for gi, g := range groups(cfg.PlaylistSize) {
		p := &Playlist{
			Idx: len(w.Playlists), PublicID: loadPublicID(kindPlaylist, len(w.Playlists)+1),
			Owner: g[0], Name: fmt.Sprintf("Load Playlist %04d", gi+1), Description: "Load test",
			Visibility: "private", License: "invited_only", CreatedAt: w.ago(day),
		}
		for _, u := range g {
			role := "editor"
			if u == g[0] {
				role = "owner"
			}
			p.Members = append(p.Members, Member{User: u, Role: role, InvitedBy: g[0], Joined: p.CreatedAt})
		}
		p.Members[0].InvitedBy = -1
		for i, song := range pick(w, songs, cfg.PlaylistSongs) {
			w.addRow(p, song, g[i%len(g)], p.CreatedAt.Add(time.Duration(i)*minute))
		}
		w.Playlists = append(w.Playlists, p)
		fx.Playlists = append(fx.Playlists, LoadPlaylist{PublicID: p.PublicID, Owner: g[0], Members: g})
		for _, u := range g {
			fx.Users[u].Playlist = gi
		}
	}

	// --- delegation circles ------------------------------------------------------
	// The owner's device, friendships with everyone in the circle, a grant
	// for the owner's live event to all but the last, where the delegates use
	// that device.
	for gi, g := range groups(cfg.DelegationSize) {
		owner := g[0]
		d := &Device{
			Idx: len(w.Devices), PublicID: loadPublicID(kindDevice, len(w.Devices)+1), Owner: owner,
			Identifier: fmt.Sprintf("lt-device-%06d", owner+1), Name: "Load Speaker", Platform: "android",
			Model: "k6", OSVersion: "14", AppVersion: "load", LastSeen: w.ago(minute), Active: true,
			CreatedAt: w.ago(day),
		}
		w.Devices = append(w.Devices, d)
		e := liveEvent(owner, fmt.Sprintf("Load Circle %04d", gi+1), g)
		// The owner's device plays it, as after their first play: the
		// delegates' licences are checked against it.
		e.Playback.Speaker = &d.Idx
		circle := LoadCircle{Owner: owner, Device: d.PublicID, Event: e.PublicID, Spare: -1}
		for i, u := range g[1:] {
			w.Friendships = append(w.Friendships, &Friendship{A: owner, B: u, Since: w.ago(day)})
			if i == len(g)-2 && len(g) > 2 {
				circle.Spare = u
				continue
			}
			w.Grants = append(w.Grants, &Grant{Device: d.Idx, Grantee: u, Event: e.Idx,
				CreatedAt: w.ago(day)})
			circle.Delegates = append(circle.Delegates, u)
		}
		fx.Circles = append(fx.Circles, circle)
		for _, u := range g {
			fx.Users[u].Circle = gi
		}
	}
	return w, fx
}

func writeFixtures(path string, fx *LoadFixtures) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(fx, "", " ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o644)
}
