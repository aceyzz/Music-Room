package main

import (
	"fmt"
	"math/big"
	"math/rand/v2"
	"time"
)

// The world is the whole demo dataset, built in memory before anything touches
// a database. Two readers consume it -- write.go (Postgres + the OpenFGA outbox
// + the image volume) and doc.go (docs/annex/init_script_doc.md) -- so the doc can
// never describe something the seeder did not create.
//
// References between entities are slice indices into World, not database ids:
// ids are reserved from the sequences at write time (write.go), so the world
// stays the same whatever the database already holds.
//
// Everything is deterministic for a given `now`: one PCG seed drives every
// random choice, and public ids are fixed (publicID below). Times are relative
// to `now`, which is why the doc never prints an absolute date -- it would make
// the committed doc stale the next day.

// Password is every seeded account's password (the user's choice: one shared
// password, so any account can be opened in a second).
const Password = "musicroom42"

// EmailDomain is reserved for documentation (RFC 2606 lists .test), so no seeded
// address can ever reach a real inbox.
const EmailDomain = "musicroom.test"

// DevSessionToken is a session for Alex whose plaintext is known, so the app's
// DEV_SESSION_TOKEN (.env) can skip the login screen. Only its SHA-256 is
// stored, like every session. It is a demo credential and nothing else.
const DevSessionToken = "seed-dev-session-alex-musicroom42-do-not-use-in-prod"

// VerificationCode is the pending email-verification code of the unverified
// account, so /verify-email can be completed without reading the logs.
const VerificationCode = "424242"

// Kinds of public id. The 5eed prefix makes a seeded object recognisable in any
// log line or URL; the second group says which table it belongs to.
const (
	kindUser       = 0x0001
	kindPlaylist   = 0x0002
	kindEvent      = 0x0003
	kindQueueEntry = 0x0004
	kindDevice     = 0x0005
	kindImage      = 0x0006
	kindSession    = 0x0007
)

// publicID is a fixed, valid UUID: 5eed<kind>-0000-4000-8000-<n>.
func publicID(kind, n int) string {
	return fmt.Sprintf("5eed%04x-0000-4000-8000-%012x", kind, n)
}

type World struct {
	Now time.Time

	Users            []*User
	Songs            []*Song
	Friendships      []*Friendship
	FriendRequests   []*FriendRequest
	Blocks           []*Block
	Playlists        []*Playlist
	Events           []*Event
	Devices          []*Device
	Grants           []*Grant
	Sessions         []*Session
	LoginAttempts    []*LoginAttempt
	UserTokens       []*UserToken
	ActivityLogs     []*ActivityLog
	Images           []*Image
	entriesCreated   int
	playlistRowCount int
	rng              *rand.Rand
	roles            socialRoles
}

// --- people ---------------------------------------------------------------

type User struct {
	Idx         int
	PublicID    string
	Email       string
	DisplayName string
	HasPassword bool
	Status      string // user_status
	Verified    bool
	CreatedAt   time.Time
	LastLoginAt *time.Time

	// Persona is the short label the doc uses ("main demo account", ...);
	// empty for the crowd.
	Persona string
	// Notes are what to look at when logged in as this user (doc only).
	Notes []string

	Profile Profile
	Avatar  *Image
	Prefs   []Pref
	OAuth   []OAuthLink
}

type Profile struct {
	FirstName, LastName, Bio, City, Country, Phone string
	BirthDate                                      string // YYYY-MM-DD, "" when unset
	// public | friends | private, in this order: first name, last name, bio,
	// birth date, location, phone, preferences.
	Visibility [7]string
}

type Pref struct {
	GenreID int64
	Genre   string
	Weight  int
}

type OAuthLink struct {
	Provider       string
	ProviderUserID string
}

type Friendship struct {
	A, B        int // user indices, in any order; write.go stores LEAST/GREATEST
	Since       time.Time
	FromRequest *FriendRequest
}

type FriendRequest struct {
	Idx       int
	From, To  int
	Status    string // friend_request_status
	Message   string
	CreatedAt time.Time
	Responded *time.Time
}

type Block struct {
	Blocker, Blocked int
	At               time.Time
}

// --- music ----------------------------------------------------------------

type Song struct {
	Idx          int
	DeezerID     int64
	Title        string
	Artist       string
	ArtistID     int64
	Album        string
	AlbumID      int64
	CoverURL     string // "" for the three tracks whose cover is removed on purpose
	PreviewURL   string // filled by the Deezer refresh; "" when offline
	Link         string
	Explicit     bool
	Rank         int32
	GenreID      int64
	FullDuration int
}

// Duration is what the app stores for every song: the 30-second Deezer preview
// is what plays, so music_provider.mapTrack writes 30 and the event player
// advances on it. The seed writes the same thing the app would.
func (s *Song) Duration() int { return 30 }

// --- playlists --------------------------------------------------------------

type Member struct {
	User      int
	Role      string // member_role
	InvitedBy int    // -1 for none
	Joined    time.Time
}

type Invitation struct {
	Invitee   int
	InvitedBy int
	Role      string // offered_role (playlists only)
	Status    string // invitation_status
	CreatedAt time.Time
	ExpiresAt *time.Time
	Responded *time.Time
}

type Playlist struct {
	Idx         int
	PublicID    string
	Owner       int
	Name        string
	Description string
	Visibility  string // resource_visibility
	License     string // edit_license
	CreatedAt   time.Time
	DeletedAt   *time.Time
	Cover       *Image

	Members     []Member // owner included
	Invitations []Invitation

	// Rows is the final content, in order. AllRows also holds rows that were
	// added and later removed: their ids appear in op payloads, so they need
	// one, exactly as a real removed row leaves its id behind in playlist_ops.
	Rows    []*PlaylistRow
	AllRows []*PlaylistRow
	Ops     []*PlaylistOp

	// Group and Note are for the doc.
	Group string
	Note  string
}

type PlaylistRow struct {
	Idx      int // global, across playlists (the id reservation order)
	Song     int
	Position *big.Rat
	AddedBy  int
	AddedAt  time.Time
}

type PlaylistOp struct {
	Revision int
	Actor    int
	Type     string // playlist_op_type
	Row      *PlaylistRow
	After    *PlaylistRow // move_song only; nil means "to the top"
	At       time.Time
}

// --- events ----------------------------------------------------------------

type Venue struct {
	Name          string
	Lat, Lng      float64
	RadiusMeters  int
	WindowStart   int // minutes since local midnight
	WindowEnd     int
	TimeZone      string
	VoteWindowSet bool
}

type Event struct {
	Idx            int
	PublicID       string
	Host           int
	Name           string
	Description    string
	Visibility     string // resource_visibility
	License        string // vote_license
	Status         string // event_status
	StartsAt       *time.Time
	EndsAt         *time.Time
	Venue          *Venue
	SourcePlaylist int // -1 for none
	CreatedAt      time.Time
	DeletedAt      *time.Time

	Members     []Member // host included, role owner
	Invitations []Invitation
	Entries     []*QueueEntry
	Playback    Playback

	Group string
	Note  string
}

type QueueEntry struct {
	Idx         int // global
	PublicID    string
	Song        int
	SuggestedBy int // -1 when the account is gone
	Status      string
	CreatedAt   time.Time
	PlayedAt    *time.Time
	Votes       []Vote
}

func (q *QueueEntry) ScoreReachedAt() time.Time {
	last := q.CreatedAt
	for _, v := range q.Votes {
		if v.At.After(last) {
			last = v.At
		}
	}
	return last
}

type Vote struct {
	User     int
	At       time.Time
	Lat, Lng *float64
}

type Playback struct {
	Current          *QueueEntry
	ControllerUser   int // -1 for none
	ControllerDevice int // -1 for none
	// The device that plays the sound, which a delegate's licence is checked
	// against (speaker_device_id); nil for none yet: the host's first play sets it.
	Speaker    *int
	Paused     bool
	PositionMs int
	StartedAt  *time.Time
	UpdatedAt  time.Time
}

// --- delegation -------------------------------------------------------------

type Device struct {
	Idx        int
	PublicID   string
	Owner      int
	Identifier string
	Name       string
	Platform   string // device_platform
	Model      string
	OSVersion  string
	AppVersion string
	LastSeen   time.Time
	Active     bool
	CreatedAt  time.Time
}

type Grant struct {
	Device    int
	Grantee   int
	Event     int // the event it is for: there is no grant for every event
	ExpiresAt *time.Time
	RevokedAt *time.Time
	CreatedAt time.Time
	Note      string
}

// --- auth and audit ---------------------------------------------------------

type Session struct {
	PublicID  string
	User      int
	Device    int // -1 for none
	Token     string
	UserAgent string
	IP        string
	ExpiresAt time.Time
	LastUsed  time.Time
	RevokedAt *time.Time
	Reason    string // session_revoked_reason, "" when not revoked
	CreatedAt time.Time
}

type LoginAttempt struct {
	Email     string
	IP        string
	Succeeded bool
	Reason    string
	At        time.Time
}

type UserToken struct {
	User      int
	Purpose   string // token_purpose
	Code      string // plaintext; only its SHA-256 is stored
	ExpiresAt time.Time
	Consumed  *time.Time
	Attempts  int
	IP        string
	CreatedAt time.Time
}

// ActivityLog targets one resource by kind and slice index; write.go turns it
// into the internal id the column holds.
type ActivityLog struct {
	User         int
	Device       int // -1 for none
	Action       string
	ResourceType string // "playlist", "event", "user", "" for none
	Resource     int
	ResultCode   int
	Metadata     map[string]any
	IP           string
	UserAgent    string
	At           time.Time
}

// --- images -----------------------------------------------------------------

// Image is an original and its 512 px thumbnail, the pair every upload path
// stores (media.NewImagePair). The profile or playlist points at the thumb.
type Image struct {
	Idx            int // pair index
	Owner          int
	Kind           string // "avatar" or "cover"
	Seed           uint64
	OrigPublicID   string
	ThumbPublicID  string
	OrigKey        string
	ThumbKey       string
	CreatedAt      time.Time
	PlaylistPublic string // cover only
}

// --- building ---------------------------------------------------------------

// Build assembles the world. The order matters only through the RNG: changing
// what an early step draws reshuffles everything after it, which is fine (the
// doc is regenerated from the same world) but makes diffs noisy.
func Build(now time.Time) *World {
	w := &World{Now: now, rng: rand.New(rand.NewPCG(42, 2026))}
	w.buildSongs()
	w.buildPeople()
	w.buildSocial()
	w.buildDevices()
	w.buildPlaylists()
	w.buildEvents()
	w.buildGrants()
	w.buildHistory()
	return w
}

// ago is now minus d, the way every relative time here is spelled.
func (w *World) ago(d time.Duration) time.Time { return w.Now.Add(-d) }

func (w *World) in(d time.Duration) time.Time { return w.Now.Add(d) }

func ptr[T any](v T) *T { return &v }

const (
	minute = time.Minute
	hour   = time.Hour
	day    = 24 * time.Hour
)

// between returns a time uniformly between from and to.
func (w *World) between(from, to time.Time) time.Time {
	span := to.Sub(from)
	if span <= 0 {
		return from
	}
	return from.Add(time.Duration(w.rng.Int64N(int64(span))))
}

// pick returns n distinct elements of pool, in random order.
func pick[T any](w *World, pool []T, n int) []T {
	if n > len(pool) {
		n = len(pool)
	}
	idx := w.rng.Perm(len(pool))[:n]
	out := make([]T, n)
	for i, j := range idx {
		out[i] = pool[j]
	}
	return out
}

func (w *World) newImage(owner int, kind string, created time.Time) *Image {
	n := len(w.Images)
	prefix := "avatars"
	if kind == "cover" {
		prefix = "playlists"
	}
	img := &Image{
		Idx: n, Owner: owner, Kind: kind, Seed: w.rng.Uint64(),
		OrigPublicID:  publicID(kindImage, 2*n+1),
		ThumbPublicID: publicID(kindImage, 2*n+2),
		CreatedAt:     created,
	}
	// Same key shape as media.NewObjectKey (<prefix>/<32 hex>.<ext>), but drawn
	// from the seeded RNG so a reseed produces the same paths.
	img.OrigKey = fmt.Sprintf("%s/%016x%016x.png", prefix, w.rng.Uint64(), w.rng.Uint64())
	img.ThumbKey = fmt.Sprintf("%s/%016x%016x.png", prefix, w.rng.Uint64(), w.rng.Uint64())
	w.Images = append(w.Images, img)
	return img
}
