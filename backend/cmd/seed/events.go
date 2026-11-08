package main

import (
	"time"
)

// Events: every phase the app tells apart (past, current, upcoming),
// every licence, every playback state, and queues with their whole vote
// history.
//
// Alex hosts 18 of them because GetMusicEvents only lists hosted events
// (docs/annex/todo.md §3): that is what fills Home and the Events tab today. The
// other 22 are reachable by id (doc) and fill the lists once the RPC lists
// joined events too.
//
// The queue invariants, mirrored from the schema and from CastQueueVote:
//   - at most one `playing` entry, and a song at most once among queued+playing;
//   - vote_count = number of votes, one vote per (entry, user), and
//     score_reached_at = the last vote (or the entry's creation);
//   - votes happen while the entry is queued: before played_at, before now;
//   - played_at is when the song finished (MarkQueueEntryPlayed).

// The 42 Paris campus, the venue of the location_time events.
var venue42 = Venue{
	Name: "42 Paris", Lat: 48.896607, Lng: 2.318501, RadiusMeters: 150,
	WindowStart: 10 * 60, WindowEnd: 2 * 60, TimeZone: "Europe/Paris", VoteWindowSet: true,
}

type evSpec struct {
	host         int
	name, desc   string
	vis, license string
	status       string
	starts, ends *time.Duration // relative to now; required, like CreateEvent
	venue        bool
	source       string        // source playlist name, "" for none
	created      time.Duration // how long ago
	guests       []int
	roles        map[int]string // guest -> editor (viewer otherwise); no admins in the app yet
	played       int
	skipped      int
	queued       int
	playback     string // playing, paused, idle, done
	alexVotes    int    // how many queued entries Alex has voted for
	voteDensity  int    // average voters per entry
	controller   int    // controller user for a playing event, host when 0
	device       int    // controller device, -1 for none
	deletedAgo   time.Duration
	group, note  string
}

func rel(d time.Duration) *time.Duration { return &d }

func (w *World) buildEvents() {
	f := w.roles.alexFriends
	strangers := w.strangers()
	crowd := w.activeCrowd()
	friendsCircle := []int{uSarah, uLiam, uEmma, uGoogle, uIntra42, uLongName}
	circle := append(append([]int{}, friendsCircle...), f...)

	specs := []evSpec{
		// --- Alex, past: 5 ---------------------------------------------------
		{host: uAlex, name: "Rooftop Sessions #12", desc: "Sunset, city lights and the best queue we ever had.",
			vis: "public", license: "everyone", status: "ended", starts: rel(-30*day - 4*hour), ends: rel(-30*day + hour),
			source: "Rooftop Sessions Pool", created: 45 * day, guests: pick(w, circle, 14), played: 40, skipped: 3, queued: 5,
			playback: "done", voteDensity: 8, group: groupAlex, note: "The big recap: 43 played (3 skipped), a top suggester, leftovers never played"},
		{host: uAlex, name: "Birthday Dinner", desc: "Thirty candles, one playlist.",
			vis: "private", license: "invited_only", status: "ended", starts: rel(-60*day - 3*hour), ends: rel(-60*day + hour),
			created: 75 * day, guests: []int{uSarah, uLiam, uEmma, f[0], f[1], f[2]}, played: 8,
			playback: "done", voteDensity: 3, group: groupAlex, note: "Private, invited guests only"},
		{host: uAlex, name: "Silent Disco That Wasn't", desc: "The headphones never arrived.",
			vis: "public", license: "everyone", status: "ended", starts: rel(-12*day - 2*hour), ends: rel(-12 * day),
			created: 20 * day, queued: 3, playback: "idle", voteDensity: 1,
			group: groupAlex, note: "Nobody invited, nothing played: “No music was played at this event.”"},
		{host: uAlex, name: "42 Paris Piscine Closing Party", desc: "Votes only on campus.",
			vis: "public", license: "location_time", status: "ended", starts: rel(-45*day - 5*hour), ends: rel(-45 * day),
			venue: true, created: 60 * day, guests: pick(w, circle, 8), played: 12, queued: 2,
			playback: "done", voteDensity: 5, group: groupAlex, note: "Location + time licence at 42 Paris; votes carry coordinates"},
		{host: uAlex, name: "Garden Party", desc: "Sun, lemonade and a long queue.",
			vis: "public", license: "everyone", status: "ended", starts: rel(-5*day - 4*hour), ends: rel(-5 * day),
			created: 15 * day, guests: pick(w, circle, 5), played: 6, playback: "done", voteDensity: 3,
			group: groupAlex, note: "Ended: the server ends an event left quiet past its end"},

		// --- Alex, current: 5 -------------------------------------------------
		{host: uAlex, name: "Friday Warm-up — Live", desc: "Vote for what plays next!",
			vis: "public", license: "everyone", status: "live", starts: rel(-hour), ends: rel(3 * hour),
			source: "Friday Night Warm-up", created: 6 * day, guests: pick(w, circle, 19), played: 15, queued: 20,
			playback: "playing", alexVotes: 4, voteDensity: 7,
			group: groupAlex, note: "Live, a song playing, 20 in the queue; Alex already voted for 4"},
		{host: uAlex, name: "Late Night Session", desc: "Invite only. Lights low.",
			vis: "private", license: "invited_only", status: "live", starts: rel(-2 * hour), ends: rel(2 * hour),
			created: 3 * day, guests: []int{uSarah, uEmma, f[3], f[4], f[5], f[6], f[7], f[8]},
			played: 5, queued: 8, playback: "paused", alexVotes: 2, voteDensity: 3,
			group: groupAlex, note: "Live, the music paused 14 s into a song"},
		{host: uAlex, name: "Open Mic Warm-up", desc: "Doors open, music soon.",
			vis: "public", license: "everyone", status: "scheduled", starts: rel(-20 * minute), ends: rel(2*hour + 40*minute),
			created: 2 * day, guests: []int{uLiam, f[9], f[10]}, queued: 6, playback: "idle", voteDensity: 2,
			group: groupAlex, note: "`scheduled` but under way: opens live, “Nothing is playing yet”"},
		{host: uAlex, name: "42 Paris Hackathon Radio", desc: "On campus only, 10:00 to 02:00.",
			vis: "public", license: "location_time", status: "live", starts: rel(-3 * hour), ends: rel(5 * hour),
			venue: true, created: 4 * day, guests: pick(w, circle, 10), played: 7, queued: 12,
			playback: "playing", voteDensity: 4,
			group: groupAlex, note: "Location + time licence: votes from the app are refused (it sends no position)"},
		{host: uAlex, name: "Summer Festival 2026 — 3 Days", desc: "Three stages, one queue.",
			vis: "public", license: "everyone", status: "live", starts: rel(-day - 6*hour), ends: rel(2 * day),
			created: 30 * day, guests: pick(w, dedupe(append(append([]int{}, circle...), crowd...)), 40), played: 114, skipped: 6,
			queued: 30, playback: "playing", alexVotes: 3, voteDensity: 10, controller: uSarah, device: devAlexSoundbar,
			group: groupAlex, note: "Spans 3 days; Sarah drives Alex's Living Room Soundbar (delegated control)"},

		// --- Alex, upcoming: 6 ------------------------------------------------
		{host: uAlex, name: "Pre-drinks at Alex's", desc: "Bring a song, bring a friend.",
			vis: "private", license: "invited_only", status: "scheduled", starts: rel(2 * hour), ends: rel(6 * hour),
			created: 2 * day, guests: []int{uSarah, uLiam, uEmma, f[11]}, queued: 4, playback: "idle", voteDensity: 2,
			group: groupAlex, note: "Starts in 2 hours; songs already lined up"},
		{host: uAlex, name: "Sunday Brunch Beats", desc: "Pancakes at 11.",
			vis: "public", license: "everyone", status: "scheduled", starts: rel(day + 2*hour), ends: rel(day + 6*hour),
			created: day, guests: []int{uEmma, f[12]}, playback: "idle",
			group: groupAlex, note: "Tomorrow; nothing lined up yet"},
		{host: uAlex, name: "Lisbon Trip Week", desc: "Seven days, one shared queue for the car, the beach and the bars.",
			vis: "public", license: "everyone", status: "scheduled", starts: rel(7 * day), ends: rel(12 * day),
			source: "Road Trip 2026", created: 10 * day, guests: []int{uLiam, uGoogle, uSarah, f[13], f[14], f[15], f[16]},
			queued: 12, playback: "idle", voteDensity: 1,
			group: groupAlex, note: "Next week, five days long; queue seeded from the Road Trip 2026 playlist"},
		{host: uAlex, name: "New Year's Eve 2027", desc: "The big one. Dress code: sequins.",
			vis: "private", license: "invited_only", status: "scheduled", starts: rel(90 * day), ends: rel(90*day + 8*hour),
			created: 14 * day, guests: pick(w, dedupe(append(append([]int{}, circle...), crowd...)), 45), roles: map[int]string{uLiam: "editor"},
			queued: 10, playback: "idle", voteDensity: 2,
			group: groupAlex, note: "45 guests: the avatar row shows “+N”"},
		{host: uAlex, name: "Quiet Listening Club", desc: "",
			vis: "public", license: "invited_only", status: "scheduled", starts: rel(3 * day), ends: rel(3*day + 2*hour),
			created: 5 * day, guests: []int{uEmma, uIntra42, f[17]}, queued: 2, playback: "idle", voteDensity: 1,
			group: groupAlex, note: "No description"},
		{host: uAlex, name: "The Absolutely Legendary End-of-Semester Party for Everyone Who Survived the Piscine",
			desc: "Long name, long night.", vis: "public", license: "everyone", status: "scheduled",
			starts: rel(14 * day), ends: rel(14*day + 6*hour), created: 3 * day, guests: pick(w, circle, 10),
			queued: 5, playback: "idle", voteDensity: 2, group: groupAlex, note: "Very long name (84 characters)"},

		// --- Alex, far ahead: 2 ------------------------------------------------
		{host: uAlex, name: "Vinyl Swap", desc: "Bring the records you no longer play.",
			vis: "public", license: "everyone", status: "scheduled", starts: rel(24*day + 14*hour),
			ends: rel(24*day + 18*hour), created: 50 * day, guests: []int{uLiam, f[18]},
			queued: 2, playback: "idle", voteDensity: 1, group: groupAlex, note: "Weeks ahead"},
		{host: uAlex, name: "Next Rooftop", desc: "Drafts.",
			vis: "private", license: "invited_only", status: "scheduled", starts: rel(40*day + 19*hour),
			ends: rel(40*day + 23*hour), created: 8 * day, playback: "idle",
			group: groupAlex, note: "Nobody invited: “No one invited yet.”"},

		// --- others, Alex is a member: 10 -------------------------------------
		{host: uSarah, name: "Rooftop Sessions #13 — Live", desc: "Round thirteen. Alex co-hosts.",
			vis: "public", license: "invited_only", status: "live", starts: rel(-90 * minute), ends: rel(150 * minute),
			created: 9 * day, guests: append([]int{uAlex, uLiam, uEmma}, pick(w, f, 9)...),
			played: 20, queued: 15, playback: "playing", alexVotes: 3, voteDensity: 6,
			group: groupNotAlex, note: "Alex is invited to someone else's live event"},
		{host: uLiam, name: "Campfire Night", desc: "Guitars out.",
			vis: "public", license: "everyone", status: "live", starts: rel(-40 * minute), ends: rel(3 * hour),
			created: 4 * day, guests: []int{uAlex, uSarah, uEmma, f[0]}, played: 4, queued: 9, playback: "playing",
			alexVotes: 2, voteDensity: 3, group: groupNotAlex, note: "Alex is a guest: the vote-only view"},
		{host: uEmma, name: "Piano Recital Afterparty", desc: "",
			vis: "private", license: "invited_only", status: "live", starts: rel(-hour), ends: rel(2 * hour),
			created: 6 * day, guests: []int{uAlex, uSarah, f[1], f[2]}, roles: map[int]string{uAlex: "editor"},
			played: 3, queued: 6, playback: "paused", voteDensity: 2, group: groupNotAlex, note: "Live, the music paused; Alex is editor"},
		{host: uSarah, name: "Jazz Brunch Live", desc: "Sunday, 11:00, croissants provided.",
			vis: "public", license: "everyone", status: "scheduled", starts: rel(2*day + 3*hour), ends: rel(2*day + 6*hour),
			created: 7 * day, guests: []int{uAlex, uEmma}, queued: 5, playback: "idle", voteDensity: 1,
			group: groupNotAlex, note: "Upcoming; Alex is a guest"},
		{host: f[3], name: "Basement Techno", desc: "Bring earplugs.",
			vis: "public", license: "everyone", status: "ended", starts: rel(-9*day - 5*hour), ends: rel(-9 * day),
			created: 20 * day, guests: append([]int{uAlex}, pick(w, crowd, 12)...), played: 25, skipped: 1,
			playback: "done", voteDensity: 6, group: groupNotAlex, note: "Past; Alex was a guest"},
		{host: uNoah, name: "Noah's Housewarming", desc: "New flat, old records.",
			vis: "private", license: "invited_only", status: "scheduled", starts: rel(5 * day), ends: rel(5*day + 5*hour),
			created: 2 * day, guests: []int{uAlex, f[4]}, queued: 3, playback: "idle", voteDensity: 1,
			group: groupNotAlex, note: "Invited by someone who isn't Alex's friend yet"},
		{host: uGoogle, name: "Pop Quiz Night", desc: "Name that tune.",
			vis: "public", license: "everyone", status: "ended", starts: rel(-20*day - 3*hour), ends: rel(-20 * day),
			created: 30 * day, guests: []int{uAlex, uSarah, f[5]}, played: 6, playback: "done", voteDensity: 2,
			group: groupNotAlex, note: "Past"},
		{host: uIntra42, name: "42 Game Jam Radio", desc: "48 hours of chiptune and coffee.",
			vis: "public", license: "everyone", status: "live", starts: rel(-20 * hour), ends: rel(28 * hour),
			created: 12 * day, guests: []int{uAlex, uLongName}, roles: map[int]string{uAlex: "editor"}, queued: 7,
			playback: "idle", voteDensity: 2, group: groupNotAlex, note: "Live but idle: nothing playing"},
		{host: f[6], name: "Wedding of Jordan & Riley", desc: "First dance at 21:00 sharp.",
			vis: "private", license: "invited_only", status: "scheduled", starts: rel(30 * day), ends: rel(30*day + 10*hour),
			created: 40 * day, guests: append([]int{uAlex, uSarah}, pick(w, crowd, 28)...), queued: 8, playback: "idle",
			voteDensity: 2, group: groupNotAlex, note: "30 guests"},
		{host: uSarah, name: "Sarah's Birthday", desc: "Twenty-nine again.",
			vis: "private", license: "invited_only", status: "ended", starts: rel(-100*day - 4*hour), ends: rel(-100 * day),
			created: 120 * day, guests: []int{uAlex, uLiam, uEmma, uGhost, f[7]}, played: 20, playback: "done",
			voteDensity: 3, group: groupNotAlex, note: "Past, private"},

		// --- others, Alex isn't in them: 12 -----------------------------------
		{host: strangers[0], name: "Members Only Listening Party", desc: "Invite only. You know who you are.",
			vis: "public", license: "invited_only", status: "live", starts: rel(-30 * minute), ends: rel(3 * hour),
			created: 5 * day, guests: pick(w, strangers[1:], 8), played: 3, queued: 8, playback: "playing", voteDensity: 3,
			group: groupOthersOnly, note: "Public, invited voters only: Alex can open it but “You can't vote in this event”; Alex has a pending invitation"},
		{host: strangers[1], name: "Open Air Cinema Soundtracks", desc: "Films under the stars.",
			vis: "public", license: "everyone", status: "live", starts: rel(-2 * hour), ends: rel(hour),
			created: 10 * day, guests: pick(w, strangers, 6), played: 15, queued: 14, playback: "playing", voteDensity: 6,
			group: groupOthersOnly, note: "Public and open: Alex may vote without being invited"},
		{host: strangers[2], name: "Reggae Sunsplash Jam", desc: "",
			vis: "public", license: "everyone", status: "live", starts: rel(-4 * hour), ends: rel(4 * hour),
			created: 15 * day, guests: pick(w, crowd, 15), played: 25, queued: 20, playback: "playing", voteDensity: 7,
			group: groupOthersOnly},
		{host: strangers[3], name: "Office Friday Drinks", desc: "Private, coworkers only.",
			vis: "private", license: "invited_only", status: "live", starts: rel(-hour), ends: rel(2 * hour),
			created: 3 * day, guests: pick(w, strangers, 7), played: 5, queued: 6, playback: "playing", voteDensity: 3,
			group: groupOthersOnly, note: "Private: Alex can't open it"},
		{host: strangers[4], name: "K-Pop Dance Practice", desc: "Learn the choreo.",
			vis: "public", license: "everyone", status: "scheduled", starts: rel(4 * day), ends: rel(4*day + 3*hour),
			created: 6 * day, guests: pick(w, crowd, 9), queued: 6, playback: "idle", voteDensity: 2, group: groupOthersOnly},
		{host: strangers[5], name: "Metalheads United", desc: "Loud. Very loud.",
			vis: "public", license: "everyone", status: "scheduled", starts: rel(10 * day), ends: rel(10*day + 5*hour),
			created: 8 * day, guests: pick(w, crowd, 12), queued: 4, playback: "idle", voteDensity: 2, group: groupOthersOnly},
		{host: strangers[6], name: "Secret Santa Party", desc: "",
			vis: "private", license: "invited_only", status: "scheduled", starts: rel(80 * day), ends: rel(80*day + 5*hour),
			created: 2 * day, guests: pick(w, strangers, 10), playback: "idle", group: groupOthersOnly, note: "Private"},
		{host: strangers[7], name: "Lagos Nights", desc: "Afrobeats till dawn.",
			vis: "public", license: "everyone", status: "ended", starts: rel(-16*day - 6*hour), ends: rel(-16 * day),
			created: 25 * day, guests: pick(w, crowd, 20), played: 40, skipped: 2, playback: "done", voteDensity: 8,
			group: groupOthersOnly},
		{host: strangers[8], name: "Classical Mornings", desc: "Coffee and Chopin.",
			vis: "public", license: "everyone", status: "ended", starts: rel(-50*day - 2*hour), ends: rel(-50 * day),
			created: 55 * day, guests: pick(w, crowd, 6), played: 9, playback: "done", voteDensity: 3, group: groupOthersOnly},
		{host: strangers[9], name: "Uni Radio Takeover", desc: "Students run the queue.",
			vis: "public", license: "location_time", status: "ended", starts: rel(-70*day - 6*hour), ends: rel(-70 * day),
			venue: true, created: 80 * day, guests: pick(w, crowd, 10), played: 12, playback: "done", voteDensity: 4,
			group: groupOthersOnly, note: "Location + time licence"},
		{host: strangers[10], name: "Beach Bonfire", desc: "Driftwood and a speaker.",
			vis: "public", license: "everyone", status: "scheduled", starts: rel(12*day + 20*hour),
			ends: rel(13 * day), created: 20 * day, guests: pick(w, crowd, 4),
			queued: 3, playback: "idle", voteDensity: 1, group: groupOthersOnly},
		{host: strangers[11], name: "Cancelled Rave", desc: "Called off.",
			vis: "public", license: "everyone", status: "scheduled", starts: rel(6 * day), ends: rel(6*day + 6*hour),
			created: 30 * day, guests: pick(w, crowd, 5), queued: 2, playback: "idle", voteDensity: 1,
			deletedAgo: 4 * day, group: groupOthersOnly, note: "Soft-deleted (deleted_at set): invisible everywhere"},
	}
	for _, s := range specs {
		if s.device == 0 {
			s.device = -1
		}
		w.buildEvent(s)
	}
	w.eventInvitations()
}

func (w *World) playlistByName(name string) int {
	for _, p := range w.Playlists {
		if p.Name == name {
			return p.Idx
		}
	}
	panic("no playlist " + name)
}

func (w *World) buildEvent(s evSpec) *Event {
	e := &Event{
		Idx: len(w.Events), PublicID: publicID(kindEvent, len(w.Events)+1),
		Host: s.host, Name: s.name, Description: s.desc, Visibility: s.vis, License: s.license,
		Status: s.status, SourcePlaylist: -1, CreatedAt: w.ago(s.created), Group: s.group, Note: s.note,
	}
	w.Events = append(w.Events, e)
	if s.starts != nil {
		e.StartsAt, e.EndsAt = ptr(w.in(*s.starts)), ptr(w.in(*s.ends))
	}
	if s.venue {
		v := venue42
		e.Venue = &v
	}
	if s.source != "" {
		e.SourcePlaylist = w.playlistByName(s.source)
	}

	e.Members = []Member{{User: s.host, Role: "owner", InvitedBy: -1, Joined: e.CreatedAt}}
	seen := map[int]bool{s.host: true}
	for _, g := range s.guests {
		if seen[g] || !w.active(g) {
			continue
		}
		seen[g] = true
		role := "viewer"
		if r, ok := s.roles[g]; ok {
			role = r
		}
		e.Members = append(e.Members, Member{User: g, Role: role, InvitedBy: s.host,
			Joined: w.between(e.CreatedAt, minTime(w.Now, e.CreatedAt.Add(5*day)))})
	}

	// Who takes part: members always; on an open public event, strangers
	// too (most people at a public event are not on the guest list).
	var members []int
	for _, m := range e.Members {
		members = append(members, m.User)
	}
	voters := members
	if e.Visibility == "public" && e.License != "invited_only" {
		voters = dedupe(append(append([]int{}, members...), pick(w, w.activeCrowd(), 15)...))
	}

	// The time span the queue lived in: the event's window, or the days before
	// it for songs lined up ahead of an upcoming event.
	from, to := e.CreatedAt.Add(hour), w.ago(2*minute)
	if e.StartsAt != nil && e.StartsAt.Before(w.Now) {
		from = *e.StartsAt
		if e.EndsAt.Before(w.Now) {
			to = *e.EndsAt
		}
	}

	nPlayed := s.played + s.skipped
	songs := pick(w, w.allSongs(), nPlayed+s.queued+1)
	if e.SourcePlaylist >= 0 {
		// Seeded from the playlist, like CreateEvent does: its songs first,
		// suggested by the host.
		var src []int
		for _, r := range w.Playlists[e.SourcePlaylist].Rows {
			src = append(src, r.Song)
		}
		songs = dedupe(append(src, songs...))
	}
	fromSource := map[int]bool{}
	if e.SourcePlaylist >= 0 {
		for _, r := range w.Playlists[e.SourcePlaylist].Rows {
			fromSource[r.Song] = true
		}
	}

	suggesters := voters
	newEntry := func(song int, created time.Time) *QueueEntry {
		q := &QueueEntry{
			Idx: w.entriesCreated, PublicID: publicID(kindQueueEntry, w.entriesCreated+1),
			Song: song, SuggestedBy: suggesters[w.rng.IntN(len(suggesters))], Status: "queued", CreatedAt: created,
		}
		if fromSource[song] {
			q.CreatedAt, q.SuggestedBy = e.CreatedAt, s.host
		}
		w.entriesCreated++
		e.Entries = append(e.Entries, q)
		return q
	}
	castVotes := func(q *QueueEntry, until time.Time, n int) {
		for _, v := range pick(w, voters, n) {
			if v == uAlex {
				continue // Alex's votes are placed on purpose below
			}
			at := w.between(q.CreatedAt, until)
			vote := Vote{User: v, At: at}
			if e.Venue != nil {
				lat := e.Venue.Lat + (w.rng.Float64()-0.5)*0.002
				lng := e.Venue.Lng + (w.rng.Float64()-0.5)*0.002
				vote.Lat, vote.Lng = &lat, &lng
			}
			q.Votes = append(q.Votes, vote)
		}
	}
	votesFor := func() int {
		if s.voteDensity == 0 {
			return 0
		}
		return w.rng.IntN(2*s.voteDensity + 1)
	}

	// Played (and skipped) songs, oldest first.
	if nPlayed > 0 {
		end := to
		if s.playback == "playing" || s.playback == "paused" {
			end = to.Add(-5 * minute)
		}
		c := newClock(w, from, end, nPlayed)
		skipped := map[int]bool{}
		for _, i := range w.rng.Perm(nPlayed)[:s.skipped] {
			skipped[i] = true
		}
		for i := 0; i < nPlayed; i++ {
			playedAt := c.next()
			q := newEntry(songs[i], w.between(from.Add(-2*hour), playedAt.Add(-time.Minute)))
			q.Status = "played"
			if skipped[i] {
				q.Status = "skipped"
			}
			q.PlayedAt = ptr(playedAt)
			castVotes(q, playedAt.Add(-time.Minute), votesFor())
		}
	}
	// The one playing now, or paused.
	var current *QueueEntry
	if s.playback == "playing" || s.playback == "paused" {
		current = newEntry(songs[nPlayed], w.between(from, w.ago(10*minute)))
		current.Status = "playing"
		castVotes(current, w.ago(6*minute), votesFor())
	}
	// Still queued.
	queuedSongs := songs[nPlayed+1:]
	if len(queuedSongs) > s.queued {
		queuedSongs = queuedSongs[:s.queued]
	}
	for _, song := range queuedSongs {
		q := newEntry(song, w.between(from, to.Add(-time.Minute)))
		castVotes(q, to, votesFor())
	}
	// Alex's own votes, on the queued entries with the most votes, so the
	// filled ballot icon shows near the top of the list.
	if s.alexVotes > 0 {
		var open []*QueueEntry
		for _, q := range e.Entries {
			if q.Status == "queued" {
				open = append(open, q)
			}
		}
		for _, q := range pick(w, open, s.alexVotes) {
			q.Votes = append(q.Votes, Vote{User: uAlex, At: w.between(q.CreatedAt, to)})
		}
	}
	// One suggestion whose author's account is gone (suggested_by_id SET NULL).
	if s.name == "Rooftop Sessions #12" {
		e.Entries[2].SuggestedBy = -1
	}

	// Playback.
	e.Playback = Playback{Paused: true, ControllerUser: -1, ControllerDevice: -1, UpdatedAt: e.CreatedAt}
	controller := s.host
	if s.controller != 0 {
		controller = s.controller
	}
	switch s.playback {
	case "playing":
		started := w.ago(12 * time.Second)
		e.Playback = Playback{Current: current, ControllerUser: controller, ControllerDevice: s.device,
			Paused: false, StartedAt: &started, UpdatedAt: started}
	case "paused":
		started := w.ago(25 * minute)
		e.Playback = Playback{Current: current, ControllerUser: controller, ControllerDevice: s.device,
			Paused: true, PositionMs: 14000, StartedAt: &started, UpdatedAt: started.Add(14 * time.Second)}
	case "done":
		// The last song finished and nothing followed: the radio is silent.
		last := e.Entries[nPlayed-1]
		e.Playback = Playback{ControllerUser: controller, ControllerDevice: -1, Paused: true,
			StartedAt: ptr(last.PlayedAt.Add(-30 * time.Second)), UpdatedAt: *last.PlayedAt}
	}
	if s.deletedAgo > 0 {
		e.DeletedAt = ptr(w.ago(s.deletedAgo))
	}
	return e
}

func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}

func dedupe(xs []int) []int {
	seen := map[int]bool{}
	var out []int
	for _, x := range xs {
		if !seen[x] {
			seen[x] = true
			out = append(out, x)
		}
	}
	return out
}

func (w *World) eventByName(name string) *Event {
	for _, e := range w.Events {
		if e.Name == name {
			return e
		}
	}
	panic("no event " + name)
}

// eventInvitations: every status, around a few events. Accepted invitations
// point at members; pending ones at people who are not members yet.
func (w *World) eventInvitations() {
	isMember := func(e *Event, u int) bool {
		for _, m := range e.Members {
			if m.User == u {
				return true
			}
		}
		return false
	}
	invite := func(e *Event, u int, status string) {
		at := w.between(e.CreatedAt, minTime(w.ago(time.Hour), e.CreatedAt.Add(3*day)))
		inv := Invitation{Invitee: u, InvitedBy: e.Host, Status: status, CreatedAt: at}
		switch status {
		case "pending":
			inv.ExpiresAt = ptr(w.in(14 * day))
		case "expired":
			inv.ExpiresAt = ptr(at.Add(2 * day))
		default:
			inv.Responded = ptr(at.Add(time.Duration(1+w.rng.IntN(30)) * hour))
		}
		e.Invitations = append(e.Invitations, inv)
	}

	// The New Year's Eve guest list: every guest accepted an invitation,
	// a few more are pending, some declined.
	nye := w.eventByName("New Year's Eve 2027")
	for _, m := range nye.Members[1:] {
		invite(nye, m.User, "accepted")
	}
	outsiders := 0
	for _, c := range w.activeCrowd() {
		if isMember(nye, c) {
			continue
		}
		status := []string{"pending", "pending", "pending", "pending", "pending", "pending", "declined", "declined", "declined", "declined", "revoked", "expired"}[outsiders]
		invite(nye, c, status)
		outsiders++
		if outsiders == 12 {
			break
		}
	}
	// Alex's own invitations from others.
	members := w.eventByName("Members Only Listening Party")
	invite(members, uAlex, "pending")
	for _, m := range members.Members[1:] {
		invite(members, m.User, "accepted")
	}
	for _, name := range []string{"Noah's Housewarming", "Rooftop Sessions #13 — Live", "Wedding of Jordan & Riley"} {
		e := w.eventByName(name)
		for _, m := range e.Members[1:] {
			invite(e, m.User, "accepted")
		}
	}
	pre := w.eventByName("Pre-drinks at Alex's")
	invite(pre, uNoah, "pending")
	invite(pre, uGhost, "declined")
	invite(w.eventByName("Late Night Session"), uLongName, "revoked")
	invite(w.eventByName("Quiet Listening Club"), uFresh, "expired")
}
