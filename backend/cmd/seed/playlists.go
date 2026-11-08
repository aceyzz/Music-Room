package main

import (
	"math/big"
	"sort"
	"time"
)

// Playlists, with the edit history that produced them.
//
// Every song in a playlist arrives through an add_song op and every reorder is
// a move_song op, positions computed exactly as the SQL does (MovePlaylistSong:
// midpoint (a+b)*0.5 between two rows, anchor+1 after the last, first-1 at the
// top; AppendSongToPlaylist: MAX+1). So `revision` is the op count, revisions
// are gapless, and ListPlaylistOpsSince replays to the rows that are there.
// big.Rat holds the positions: every midpoint is a dyadic rational, so it
// prints as an exact decimal, as NUMERIC stores it.

type plSpec struct {
	owner        int
	name, desc   string
	vis, license string
	age          time.Duration // how long ago it was created
	cover        bool
	genres       []int64
	songs        []int // explicit songs, used instead of genres when set
	size         int
	// No admins: the app has owner and invited only (no admin role yet).
	editors      []int
	viewers      []int
	contributors []int // non-members who edit an open (everyone) public playlist
	removes      int
	moves        int
	dupSong      int // -1 for none
	dupExtra     int // extra copies of dupSong
	deleted      time.Duration
	group, note  string
}

const (
	groupAlex       = "Owned by Alex"
	groupShared     = "Shared with Alex"
	groupFriends    = "Friends' playlists"
	groupStrangers  = "Public, by people Alex doesn't know"
	groupPrivate    = "Private, Alex can't open them"
	groupDeleted    = "Soft-deleted"
	groupNotAlex    = "Hosted by others, Alex is a member"
	groupOthersOnly = "Others' events, Alex isn't in them"
)

func (w *World) buildPlaylists() {
	none := -1
	friendsCrowd := w.roles.alexFriends
	strangers := w.strangers()

	specs := []plSpec{
		// --- owned by Alex: 12 ------------------------------------------------
		{owner: uAlex, name: "Friday Night Warm-up", desc: "Start slow, end loud. Anyone can add.",
			vis: "public", license: "everyone", age: 300 * day, cover: true, genres: []int64{106, 113}, size: 35,
			contributors: []int{uSarah, uLiam, friendsCrowd[0], friendsCrowd[1]}, removes: 4, moves: 6, dupSong: none,
			group: groupAlex, note: "Public, anyone can edit; edited by 5 people"},
		{owner: uAlex, name: "Deep Focus", desc: "No lyrics, no distractions.",
			vis: "private", license: "invited_only", age: 250 * day, cover: true, genres: []int64{98, 129, 173}, size: 40,
			editors: []int{uSarah, uEmma, uIntra42}, removes: 3, moves: 5, dupSong: none,
			group: groupAlex, note: "Private, invited editors only (3 editors)"},
		{owner: uAlex, name: "Road Trip 2026", desc: "For the drive to the coast. Liam is in charge of the folk.",
			vis: "public", license: "invited_only", age: 120 * day, cover: true, genres: []int64{152, 132, 466}, size: 18,
			editors: []int{uLiam, uGoogle}, removes: 2, moves: 3, dupSong: none,
			group: groupAlex, note: "Public to read, only invited people edit; pending and declined invitations"},
		{owner: uAlex, name: "Empty Canvas", desc: "",
			vis: "public", license: "everyone", age: 2 * day, genres: nil, size: 0, dupSong: none,
			group: groupAlex, note: "Empty: “No songs yet. Add one with +.”"},
		{owner: uAlex, name: "Duplicates Welcome", desc: "The same banger, three times. On purpose.",
			vis: "public", license: "everyone", age: 40 * day, cover: true, genres: []int64{106}, size: 5,
			dupSong: w.songByDeezer(3135553), dupExtra: 2,
			group: groupAlex, note: "One More Time ×3 (added with allow_duplicate)"},
		{owner: uAlex, name: "The Long One", desc: "120 songs. Bring snacks.",
			vis: "public", license: "everyone", age: 200 * day, cover: true, songs: pick(w, w.allSongs(), 126), size: 120,
			contributors: []int{uSarah}, removes: 6, moves: 10, dupSong: none,
			group: groupAlex, note: "120 songs, to scroll"},
		{owner: uAlex, name: "Reordered a Lot", desc: "Sarah and Alex could not agree on the order.",
			vis: "public", license: "invited_only", age: 90 * day, cover: true, genres: []int64{85, 152}, size: 15,
			editors: []int{uSarah}, moves: 60, dupSong: none,
			group: groupAlex, note: "60 moves: fractional positions in the database"},
		{owner: uAlex, name: "🌙 Late Night Vibes", desc: "After 2am only.",
			vis: "private", license: "everyone", age: 75 * day, cover: true, genres: []int64{165, 169, 106}, size: 12,
			editors: []int{uEmma}, removes: 1, moves: 2, dupSong: none,
			group: groupAlex, note: "Emoji in the name; private but every member may edit"},
		{owner: uAlex, name: "The Ultimate Collection of Songs That Remind Me of Summer 2019 in Lisbon",
			vis: "public", license: "everyone", age: 160 * day, genres: []int64{197, 132}, size: 9, dupSong: none,
			group: groupAlex, note: "72-character name, no cover"},
		{owner: uAlex, name: "Gym Hype", desc: "Explicit lyrics ahead.",
			vis: "public", license: "everyone", age: 60 * day, cover: true, genres: []int64{116, 464}, size: 20,
			contributors: []int{uNoah, friendsCrowd[2]}, removes: 2, moves: 1, dupSong: none,
			group: groupAlex, note: "Rap and metal, explicit tracks"},
		{owner: uAlex, name: "Sunday Morning", desc: "Coffee, croissants, no hurry.",
			vis: "private", license: "invited_only", age: 30 * day, genres: []int64{466, 129}, size: 14, moves: 2, dupSong: none,
			group: groupAlex, note: "Private, Alex alone, no cover"},
		{owner: uAlex, name: "Afro x Latin Party", desc: "Everybody adds one. Everybody.",
			vis: "public", license: "everyone", age: 20 * day, cover: true, genres: []int64{2, 197, 144}, size: 22,
			contributors: pick(w, strangers, 6), removes: 3, moves: 4, dupSong: none,
			group: groupAlex, note: "Songs added by 7 different people"},

		// --- shared with Alex: 6 ----------------------------------------------
		{owner: uSarah, name: "Rooftop Sessions Pool", desc: "Candidates for the next rooftop. Alex co-runs it.",
			vis: "private", license: "invited_only", age: 180 * day, cover: true, genres: []int64{129, 106, 165}, size: 30,
			editors: []int{uAlex, uLiam}, removes: 3, moves: 5, dupSong: none,
			group: groupShared, note: "Alex is invited"},
		{owner: uEmma, name: "Piano & Rain", desc: "",
			vis: "private", license: "invited_only", age: 140 * day, cover: true, genres: []int64{98, 173}, size: 16,
			editors: []int{uAlex}, moves: 2, dupSong: none,
			group: groupShared, note: "Alex is editor"},
		{owner: uLiam, name: "Campfire Songs", desc: "Acoustic only. Yes, Wonderwall is banned.",
			vis: "public", license: "invited_only", age: 210 * day, genres: []int64{466}, size: 10,
			editors: []int{uAlex, uSarah}, removes: 1, dupSong: none,
			group: groupShared, note: "Alex is editor"},
		{owner: uGoogle, name: "Pop Radar", desc: "New pop worth a listen.",
			vis: "private", license: "everyone", age: 50 * day, cover: true, genres: []int64{132}, size: 10,
			editors: []int{uAlex}, dupSong: none,
			group: groupShared, note: "Alex is editor"},
		{owner: friendsCrowd[3], name: "Crate Diggers", desc: "Deep cuts only.",
			vis: "public", license: "invited_only", age: 100 * day, cover: true, genres: []int64{169, 129, 2}, size: 24,
			editors: []int{uAlex, friendsCrowd[4]}, removes: 2, moves: 3, dupSong: none,
			group: groupShared, note: "Alex is editor"},
		{owner: uIntra42, name: "42 Coding Lo-fi", desc: "Shh. Piscine in progress.",
			vis: "private", license: "invited_only", age: 80 * day, cover: true, genres: []int64{173, 106}, size: 15,
			editors: []int{uSarah, uAlex}, dupSong: none,
			group: groupShared, note: "Alex is invited: private, and he edits it"},
	}

	// --- friends' public playlists: 10 ------------------------------------------
	friendOwners := []int{uSarah, uSarah, uLiam, uEmma, friendsCrowd[5], friendsCrowd[6], friendsCrowd[7],
		friendsCrowd[8], friendsCrowd[9], friendsCrowd[10]}
	friendNames := []string{"Jazz Brunch", "Techno Tuesday", "Pub Classics", "Milano Nights", "Rainy Day Indie",
		"Throwback Thursday", "Bass in Your Face", "Soul Kitchen", "Lisbon Sunsets", "Running 5K"}
	for i, o := range friendOwners {
		lic := "everyone"
		if i%3 == 0 {
			lic = "invited_only"
		}
		specs = append(specs, plSpec{owner: o, name: friendNames[i], vis: "public", license: lic,
			age: time.Duration(40+w.rng.IntN(250)) * day, cover: i%2 == 0,
			genres: []int64{Genres[w.rng.IntN(len(Genres))].ID, Genres[w.rng.IntN(len(Genres))].ID},
			size:   12 + w.rng.IntN(30), removes: w.rng.IntN(3), moves: w.rng.IntN(4), dupSong: none,
			contributors: pick(w, w.activeCrowd(), 2), group: groupFriends,
			note: map[string]string{"everyone": "anyone can edit", "invited_only": "read-only for Alex"}[lic]})
	}

	// --- strangers' public playlists: 14 ----------------------------------------
	strangerNames := []string{"Bossa Nova Breakfast", "Metal Monday", "K-Pop Deep Dive", "Lagos to London",
		"Ambient for Sleeping", "90s Eurodance", "Film Scores I Cry To", "Reggae Roots", "Latin Heat",
		"Study With Me", "Garage Band Practice", "Wedding Dance Floor", "Blues Highway", "Chill Electronica"}
	for i, name := range strangerNames {
		lic := "everyone"
		if i%2 == 1 {
			lic = "invited_only"
		}
		owner := strangers[i%len(strangers)]
		spec := plSpec{owner: owner, name: name, vis: "public", license: lic,
			age: time.Duration(20+w.rng.IntN(400)) * day, cover: i%3 != 2,
			genres: []int64{Genres[w.rng.IntN(len(Genres))].ID, Genres[w.rng.IntN(len(Genres))].ID},
			size:   12 + w.rng.IntN(40), removes: w.rng.IntN(4), moves: w.rng.IntN(5), dupSong: none,
			group: groupStrangers, note: map[string]string{"everyone": "anyone can edit", "invited_only": "read-only for Alex"}[lic]}
		if lic == "invited_only" {
			spec.editors = pick(w, strangers, 2)
		} else {
			spec.contributors = pick(w, w.activeCrowd(), 3)
		}
		specs = append(specs, spec)
	}

	// --- private, Alex can't open: 4 ---------------------------------------------
	specs = append(specs,
		plSpec{owner: uNoah, name: "Noah's Secret Stash", vis: "private", license: "invited_only", age: 50 * day,
			genres: []int64{116, 2}, size: 12, editors: pick(w, strangers, 1), dupSong: none, group: groupPrivate,
			note: "Alex has a pending invitation to it"},
		plSpec{owner: uGhost, name: "untitled", vis: "private", license: "invited_only", age: 180 * day,
			genres: []int64{464}, size: 7, dupSong: none, group: groupPrivate, note: "Ghost's, nobody else"},
		plSpec{owner: strangers[0], name: "Breakup Survival Kit", vis: "private", license: "everyone", age: 70 * day,
			cover: true, genres: []int64{132, 165}, size: 18, editors: pick(w, strangers[1:], 2), dupSong: none,
			group: groupPrivate},
		plSpec{owner: uSarah, name: "Surprise Party for Alex 🤫", vis: "private", license: "invited_only", age: 6 * day,
			cover: true, genres: []int64{106, 113, 132}, size: 20, editors: []int{uLiam, uEmma}, dupSong: none,
			group: groupPrivate, note: "Sarah, Liam and Emma only. Alex must not see it"},
	)

	// --- soft-deleted: 2 -------------------------------------------------------
	specs = append(specs,
		plSpec{owner: uAlex, name: "Old Party Mix", vis: "public", license: "everyone", age: 330 * day,
			genres: []int64{113}, size: 11, dupSong: none, deleted: 100 * day, group: groupDeleted, note: "deleted_at set"},
		plSpec{owner: uSarah, name: "Test playlist please ignore", vis: "private", license: "invited_only", age: 200 * day,
			genres: []int64{132}, size: 2, dupSong: none, deleted: 190 * day, group: groupDeleted, note: "deleted_at set"},
	)

	for _, s := range specs {
		w.buildPlaylist(s)
	}
	w.playlistInvitations()
}

// strangers are active crowd accounts with no relation to Alex at all.
func (w *World) strangers() []int {
	related := map[int]bool{}
	for _, f := range w.friendsOf(uAlex) {
		related[f] = true
	}
	for _, r := range w.FriendRequests {
		if r.From == uAlex {
			related[r.To] = true
		}
		if r.To == uAlex {
			related[r.From] = true
		}
	}
	var out []int
	for _, c := range w.activeCrowd() {
		if !related[c] {
			out = append(out, c)
		}
	}
	return out
}

func (w *World) buildPlaylist(s plSpec) *Playlist {
	created := w.ago(s.age)
	p := &Playlist{
		Idx: len(w.Playlists), PublicID: publicID(kindPlaylist, len(w.Playlists)+1),
		Owner: s.owner, Name: s.name, Description: s.desc, Visibility: s.vis, License: s.license,
		CreatedAt: created, Group: s.group, Note: s.note,
	}
	w.Playlists = append(w.Playlists, p)
	if s.deleted > 0 {
		p.DeletedAt = ptr(w.ago(s.deleted))
	}
	end := w.ago(hour)
	if p.DeletedAt != nil {
		end = p.DeletedAt.Add(-day)
	}
	if s.cover {
		p.Cover = w.newImage(s.owner, "cover", w.between(created, created.Add(2*day)))
		p.Cover.PlaylistPublic = p.PublicID
	}

	p.Members = []Member{{User: s.owner, Role: "owner", InvitedBy: -1, Joined: created}}
	for _, group := range []struct {
		role  string
		users []int
	}{{"editor", s.editors}, {"viewer", s.viewers}} {
		for _, u := range group.users {
			if u == s.owner {
				continue
			}
			p.Members = append(p.Members, Member{User: u, Role: group.role, InvitedBy: s.owner,
				Joined: w.between(created, created.Add(10*day))})
		}
	}

	// Who may write: the owner and editors always; on an open licence
	// also the contributors (anyone who can see the playlist may edit it).
	actors := []int{s.owner}
	actors = append(actors, s.editors...)
	if s.license == "everyone" {
		actors = append(actors, s.contributors...)
	}

	songs := s.songs
	if songs == nil && s.size+s.removes > 0 {
		pool := w.songsOf(s.genres...)
		if s.dupSong >= 0 {
			// The duplicated song comes in through its own adds below, so it
			// must not also be drawn here.
			pool = without(pool, s.dupSong)
		}
		songs = pick(w, pool, s.size+s.removes)
		if len(songs) < s.size+s.removes {
			songs = append(songs, pick(w, w.allSongs(), s.size+s.removes-len(songs))...)
		}
	}
	nOps := len(songs) + s.removes + s.moves + s.dupExtra
	if s.dupSong >= 0 {
		nOps++
	}
	clock := newClock(w, created.Add(time.Hour), end, nOps)

	for _, song := range songs {
		w.addRow(p, song, actors[w.rng.IntN(len(actors))], clock.next())
	}
	if s.dupSong >= 0 {
		for i := 0; i <= s.dupExtra; i++ {
			w.addRow(p, s.dupSong, actors[i%len(actors)], clock.next())
		}
	}
	// Removes and moves, interleaved.
	steps := make([]bool, 0, s.removes+s.moves) // true = remove
	for i := 0; i < s.removes; i++ {
		steps = append(steps, true)
	}
	for i := 0; i < s.moves; i++ {
		steps = append(steps, false)
	}
	w.rng.Shuffle(len(steps), func(i, j int) { steps[i], steps[j] = steps[j], steps[i] })
	for _, remove := range steps {
		actor := actors[w.rng.IntN(len(actors))]
		if remove {
			if len(p.Rows) == 0 {
				continue
			}
			w.removeRow(p, p.Rows[w.rng.IntN(len(p.Rows))], actor, clock.next())
			continue
		}
		if len(p.Rows) < 2 {
			continue
		}
		row := p.Rows[w.rng.IntN(len(p.Rows))]
		var after *PlaylistRow
		if anchor := w.rng.IntN(len(p.Rows) + 1); anchor < len(p.Rows) && p.Rows[anchor] != row {
			after = p.Rows[anchor]
		}
		w.moveRow(p, row, after, actor, clock.next())
	}
	return p
}

// clock hands out increasing times spread over [from, to).
type clock struct {
	w        *World
	at, step time.Duration
	from     time.Time
}

func newClock(w *World, from, to time.Time, n int) *clock {
	if n < 1 {
		n = 1
	}
	span := to.Sub(from)
	if span < time.Duration(n)*time.Second {
		span = time.Duration(n) * time.Second
	}
	return &clock{w: w, from: from, step: span / time.Duration(n)}
}

func (c *clock) next() time.Time {
	t := c.from.Add(c.at + time.Duration(c.w.rng.Int64N(int64(c.step)/2+1)))
	c.at += c.step
	return t
}

func (w *World) newRow(song, actor int, at time.Time) *PlaylistRow {
	r := &PlaylistRow{Idx: w.playlistRowCount, Song: song, AddedBy: actor, AddedAt: at}
	w.playlistRowCount++
	return r
}

func (w *World) op(p *Playlist, actor int, kind string, row, after *PlaylistRow, at time.Time) {
	p.Ops = append(p.Ops, &PlaylistOp{Revision: len(p.Ops) + 1, Actor: actor, Type: kind, Row: row, After: after, At: at})
}

// addRow is AppendSongToPlaylist: MAX(position)+1, or 1 in an empty playlist.
func (w *World) addRow(p *Playlist, song, actor int, at time.Time) {
	r := w.newRow(song, actor, at)
	r.Position = big.NewRat(1, 1)
	if n := len(p.Rows); n > 0 {
		r.Position = new(big.Rat).Add(maxPosition(p.Rows), big.NewRat(1, 1))
	}
	p.Rows = append(p.Rows, r)
	p.AllRows = append(p.AllRows, r)
	w.op(p, actor, "add_song", r, nil, at)
}

func maxPosition(rows []*PlaylistRow) *big.Rat {
	m := rows[0].Position
	for _, r := range rows[1:] {
		if r.Position.Cmp(m) > 0 {
			m = r.Position
		}
	}
	return m
}

func (w *World) removeRow(p *Playlist, row *PlaylistRow, actor int, at time.Time) {
	for i, r := range p.Rows {
		if r == row {
			p.Rows = append(p.Rows[:i:i], p.Rows[i+1:]...)
			break
		}
	}
	w.op(p, actor, "remove_song", row, nil, at)
}

// moveRow is MovePlaylistSong, row for row: the neighbours are looked up
// among the OTHER rows, so a row is never its own anchor or neighbour.
func (w *World) moveRow(p *Playlist, row, after *PlaylistRow, actor int, at time.Time) {
	var others []*PlaylistRow
	for _, r := range p.Rows {
		if r != row {
			others = append(others, r)
		}
	}
	half := big.NewRat(1, 2)
	switch {
	case after == nil:
		first := others[0].Position
		for _, r := range others[1:] {
			if r.Position.Cmp(first) < 0 {
				first = r.Position
			}
		}
		row.Position = new(big.Rat).Sub(first, big.NewRat(1, 1))
	default:
		var next *big.Rat
		for _, r := range others {
			if r.Position.Cmp(after.Position) > 0 && (next == nil || r.Position.Cmp(next) < 0) {
				next = r.Position
			}
		}
		if next == nil {
			row.Position = new(big.Rat).Add(after.Position, big.NewRat(1, 1))
		} else {
			sum := new(big.Rat).Add(after.Position, next)
			row.Position = sum.Mul(sum, half)
		}
	}
	sortRows(p.Rows)
	w.op(p, actor, "move_song", row, after, at)
}

// sortRows orders rows as GetPlaylistSongsByPlaylistID does: position, then id.
func sortRows(rows []*PlaylistRow) {
	sort.SliceStable(rows, func(i, j int) bool {
		if c := rows[i].Position.Cmp(rows[j].Position); c != 0 {
			return c < 0
		}
		return rows[i].Idx < rows[j].Idx
	})
}

// decimal prints a position exactly. Midpoints of integers have a power of two
// as denominator, which needs as many decimal digits as its exponent.
func decimal(r *big.Rat) string {
	if r.IsInt() {
		return r.Num().String()
	}
	return r.FloatString(r.Denom().BitLen())
}

// playlistInvitations: every status the invitation table can hold.
// Accepted ones point at someone who is now a member; pending ones at someone
// who is not.
func (w *World) playlistInvitations() {
	byName := map[string]*Playlist{}
	for _, p := range w.Playlists {
		byName[p.Name] = p
	}
	invite := func(p *Playlist, invitee int, status string, ageDays int) {
		at := w.ago(time.Duration(ageDays) * day)
		inv := Invitation{Invitee: invitee, InvitedBy: p.Owner, Role: "editor", Status: status, CreatedAt: at}
		switch status {
		case "pending":
			inv.ExpiresAt = ptr(w.in(time.Duration(30-ageDays) * day))
		case "expired":
			inv.ExpiresAt = ptr(at.Add(7 * day))
		default:
			inv.Responded = ptr(at.Add(time.Duration(1+w.rng.IntN(40)) * hour))
		}
		p.Invitations = append(p.Invitations, inv)
	}
	member := func(p *Playlist, u int) bool {
		for _, m := range p.Members {
			if m.User == u {
				return true
			}
		}
		return false
	}

	// Alex, invited: pending ones to answer, from a friend and from Noah.
	invite(byName["Noah's Secret Stash"], uAlex, "pending", 2)
	invite(byName["Jazz Brunch"], uAlex, "pending", 1)
	invite(byName["Pub Classics"], uAlex, "pending", 4)
	invite(byName["Crate Diggers"], uAlex, "accepted", 99)
	invite(byName["Campfire Songs"], uAlex, "accepted", 200)
	invite(byName["Techno Tuesday"], uAlex, "declined", 30)

	// Alex inviting others.
	road := byName["Road Trip 2026"]
	invite(road, uNoah, "pending", 1)
	invite(road, uLiam, "accepted", 119)
	invite(road, uGoogle, "accepted", 110)
	invite(road, uEmma, "declined", 100)
	invite(road, uGhost, "expired", 60)
	invite(byName["Deep Focus"], uSarah, "accepted", 249)
	invite(byName["Deep Focus"], uLongName, "revoked", 200)
	invite(byName["Reordered a Lot"], uFresh, "pending", 0)

	// Elsewhere.
	strangers := w.strangers()
	for i, name := range []string{"Metal Monday", "Latin Heat", "Wedding Dance Floor", "Blues Highway"} {
		p := byName[name]
		for _, c := range strangers[10+i*3:] {
			if !member(p, c) && c != p.Owner {
				status := []string{"pending", "pending", "revoked", "expired"}[i]
				invite(p, c, status, 3+i*5)
				break
			}
		}
	}
	invite(byName["Surprise Party for Alex 🤫"], uNoah, "pending", 1)
	invite(byName["Surprise Party for Alex 🤫"], uLiam, "accepted", 5)
}

func without(xs []int, x int) []int {
	out := make([]int, 0, len(xs))
	for _, v := range xs {
		if v != x {
			out = append(out, v)
		}
	}
	return out
}
