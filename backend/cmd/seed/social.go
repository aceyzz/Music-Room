package main

import (
	"fmt"
	"time"
)

// The social graph. Alex's corner of it is written by hand, so every caption
// and section of the friends page and the user page has someone to show it;
// the crowd's is random, dense enough that friend lists scroll.
//
// The invariants the database enforces, kept here so a violation fails in
// world_test.go rather than halfway through a transaction:
//   - one friendships row per unordered pair;
//   - at most one PENDING request per unordered pair (friend_requests_one_open_per_pair);
//   - no friendship and no pending request across a block (BlockUser deletes
//     the first and cancels the second).

type pairKey struct{ a, b int }

func pair(a, b int) pairKey {
	if a > b {
		a, b = b, a
	}
	return pairKey{a, b}
}

type graph struct {
	friends map[pairKey]bool
	pending map[pairKey]bool
	blocked map[pairKey]bool
}

// Named crowd roles, picked in buildSocial and reused by later steps (the
// doc lists them under Alex).
type socialRoles struct {
	alexFriends   []int // crowd only
	incoming      []int // crowd only; Noah comes on top
	outgoing      []int
	declinedByAlx []int
	declinedAlex  []int
	cancelled     []int
	exFriend      int // was Alex's friend, now blocked by Alex
	blockedByAlex int // a stranger Alex blocked
	mallory       int // blocked Alex
}

func (w *World) friendship(g *graph, a, b int, since time.Time, withRequest bool) {
	k := pair(a, b)
	if a == b || g.friends[k] || g.pending[k] || g.blocked[k] {
		panic(fmt.Sprintf("friendship %d-%d breaks the graph rules", a, b))
	}
	g.friends[k] = true
	f := &Friendship{A: a, B: b, Since: since}
	if withRequest {
		asked := since.Add(-time.Duration(1+w.rng.IntN(72)) * hour)
		f.FromRequest = w.request(a, b, "accepted", asked, &since)
	}
	w.Friendships = append(w.Friendships, f)
}

func (w *World) request(from, to int, status string, at time.Time, responded *time.Time) *FriendRequest {
	messages := []string{"", "", "Hey! We met at the rooftop thing.", "Love your playlists!", "Saw you at the last event 👋", ""}
	r := &FriendRequest{
		Idx: len(w.FriendRequests), From: from, To: to, Status: status,
		Message: messages[w.rng.IntN(len(messages))], CreatedAt: at, Responded: responded,
	}
	w.FriendRequests = append(w.FriendRequests, r)
	return r
}

func (w *World) pendingRequest(g *graph, from, to int, at time.Time) {
	k := pair(from, to)
	if from == to || g.friends[k] || g.pending[k] || g.blocked[k] {
		panic(fmt.Sprintf("pending request %d->%d breaks the graph rules", from, to))
	}
	g.pending[k] = true
	w.request(from, to, "pending", at, nil)
}

func (w *World) block(g *graph, blocker, blocked int, at time.Time) {
	k := pair(blocker, blocked)
	if g.friends[k] || g.pending[k] {
		panic(fmt.Sprintf("block %d->%d over a live relation", blocker, blocked))
	}
	g.blocked[k] = true
	w.Blocks = append(w.Blocks, &Block{Blocker: blocker, Blocked: blocked, At: at})
}

func (w *World) buildSocial() {
	g := &graph{friends: map[pairKey]bool{}, pending: map[pairKey]bool{}, blocked: map[pairKey]bool{}}
	crowd := w.crowd()
	shuffled := pick(w, crowd, len(crowd))
	take := func(n int) []int {
		out := shuffled[:n]
		shuffled = shuffled[n:]
		return out
	}

	// --- Alex ---------------------------------------------------------------
	w.roles = socialRoles{}
	w.roles.alexFriends = take(20)
	w.roles.incoming = take(3)
	w.roles.outgoing = take(3)
	w.roles.declinedByAlx = take(2)
	w.roles.declinedAlex = take(1)
	w.roles.cancelled = take(2)
	special := take(3)
	w.roles.exFriend, w.roles.blockedByAlex, w.roles.mallory = special[0], special[1], special[2]

	w.Users[w.roles.mallory].DisplayName = "Mallory Quinn"
	w.Users[w.roles.mallory].Email = "mallory.quinn@" + EmailDomain
	if w.Users[w.roles.mallory].Profile.FirstName != "" {
		w.Users[w.roles.mallory].Profile.FirstName, w.Users[w.roles.mallory].Profile.LastName = "Mallory", "Quinn"
	}
	w.Users[w.roles.mallory].Persona = "Has blocked Alex: Alex sees “This profile isn't available”"
	w.Users[w.roles.exFriend].Persona = "Was Alex's friend, then Alex blocked them"
	w.Users[w.roles.blockedByAlex].Persona = "A stranger Alex blocked"

	for _, f := range []int{uSarah, uLiam, uEmma, uGoogle, uIntra42, uLongName, uSuspended} {
		w.friendship(g, uAlex, f, w.between(w.ago(360*day), w.ago(30*day)), true)
	}
	for i, f := range w.roles.alexFriends {
		since := w.between(w.ago(300*day), w.ago(2*day))
		// A few were befriended before requests existed in the app: no
		// request row behind them (created_from_request_id stays NULL).
		w.friendship(g, uAlex, f, since, i%7 != 0)
	}
	w.pendingRequest(g, uNoah, uAlex, w.ago(3*hour))
	for i, f := range w.roles.incoming {
		w.pendingRequest(g, f, uAlex, w.ago(time.Duration(i+1)*26*hour))
	}
	for i, f := range w.roles.outgoing {
		w.pendingRequest(g, uAlex, f, w.ago(time.Duration(i+2)*31*hour))
	}
	for _, f := range w.roles.declinedByAlx {
		at := w.between(w.ago(120*day), w.ago(10*day))
		w.request(f, uAlex, "declined", at, ptr(at.Add(5*hour)))
	}
	for _, f := range w.roles.declinedAlex {
		at := w.between(w.ago(90*day), w.ago(20*day))
		w.request(uAlex, f, "declined", at, ptr(at.Add(2*day)))
	}
	for _, f := range w.roles.cancelled {
		at := w.between(w.ago(60*day), w.ago(5*day))
		w.request(uAlex, f, "cancelled", at, ptr(at.Add(30*minute)))
	}
	// The ex-friend: accepted long ago; the block deleted the friendship row,
	// so only the request survives.
	met := w.ago(220 * day)
	w.request(w.roles.exFriend, uAlex, "accepted", met, ptr(met.Add(4*hour)))
	w.block(g, uAlex, w.roles.exFriend, w.ago(15*day))
	w.block(g, uAlex, w.roles.blockedByAlex, w.ago(40*day))
	w.block(g, w.roles.mallory, uAlex, w.ago(8*day))

	// --- the other personas -------------------------------------------------
	w.friendship(g, uSarah, uLiam, w.ago(330*day), true)
	w.friendship(g, uSarah, uEmma, w.ago(310*day), true)
	w.friendship(g, uSarah, uGhost, w.ago(190*day), true)
	w.friendship(g, uLiam, uEmma, w.ago(280*day), true)
	w.friendship(g, uDeleted, crowd[0], w.ago(270*day), true)
	w.friendship(g, uDeleted, crowd[1], w.ago(260*day), true)
	friendsOf := map[int]int{uSarah: 15, uLiam: 10, uEmma: 8, uNoah: 3, uGoogle: 5, uIntra42: 6, uLongName: 4}
	for _, p := range []int{uSarah, uLiam, uEmma, uNoah, uGoogle, uIntra42, uLongName} {
		added := 0
		for _, c := range pick(w, crowd, len(crowd)) {
			if added == friendsOf[p] {
				break
			}
			k := pair(p, c)
			if g.friends[k] || g.pending[k] || g.blocked[k] || c == w.roles.mallory {
				continue
			}
			w.friendship(g, p, c, w.between(w.ago(300*day), w.ago(day)), w.rng.IntN(8) != 0)
			added++
		}
	}

	// --- crowd blocks, then a random crowd graph around them ------------------
	for len(w.Blocks) < 8 {
		a, b := crowd[w.rng.IntN(len(crowd))], crowd[w.rng.IntN(len(crowd))]
		k := pair(a, b)
		if a == b || g.friends[k] || g.pending[k] || g.blocked[k] {
			continue
		}
		w.block(g, a, b, w.between(w.ago(200*day), w.ago(day)))
	}
	for len(w.Friendships) < 420 {
		a, b := crowd[w.rng.IntN(len(crowd))], crowd[w.rng.IntN(len(crowd))]
		k := pair(a, b)
		if a == b || g.friends[k] || g.pending[k] || g.blocked[k] {
			continue
		}
		since := w.between(maxTime(w.Users[a].CreatedAt, w.Users[b].CreatedAt), w.ago(hour))
		w.friendship(g, a, b, since, w.rng.IntN(7) != 0)
	}
	pending := 0
	for _, r := range w.FriendRequests {
		if r.Status == "pending" {
			pending++
		}
	}
	for pending < 45 {
		a, b := crowd[w.rng.IntN(len(crowd))], crowd[w.rng.IntN(len(crowd))]
		k := pair(a, b)
		if a == b || g.friends[k] || g.pending[k] || g.blocked[k] {
			continue
		}
		w.pendingRequest(g, a, b, w.between(w.ago(20*day), w.ago(hour)))
		pending++
	}
	// Declined and cancelled history: these may repeat a pair (a declined
	// request does not stop a later one), but never sit across a block.
	for history := 0; history < 40; {
		a, b := crowd[w.rng.IntN(len(crowd))], crowd[w.rng.IntN(len(crowd))]
		if a == b || g.blocked[pair(a, b)] {
			continue
		}
		at := w.between(w.ago(300*day), w.ago(2*day))
		status := "declined"
		if w.rng.IntN(3) == 0 {
			status = "cancelled"
		}
		w.request(a, b, status, at, ptr(at.Add(time.Duration(1+w.rng.IntN(48))*hour)))
		history++
	}
}

func maxTime(a, b time.Time) time.Time {
	if a.After(b) {
		return a
	}
	return b
}

// friendsOf lists u's friends (any status).
func (w *World) friendsOf(u int) []int {
	var out []int
	for _, f := range w.Friendships {
		switch u {
		case f.A:
			out = append(out, f.B)
		case f.B:
			out = append(out, f.A)
		}
	}
	return out
}

func (w *World) areFriends(a, b int) bool {
	for _, f := range w.Friendships {
		if pair(f.A, f.B) == pair(a, b) {
			return true
		}
	}
	return false
}

// active reports whether u is an account the app shows anywhere.
func (w *World) active(u int) bool { return w.Users[u].Status == "active" }

// activeCrowd is the crowd minus accounts that must not appear in random
// memberships: Mallory (who blocked Alex) and the two Alex blocked, so no
// shared playlist or event puts them back in front of Alex.
func (w *World) activeCrowd() []int {
	var out []int
	for _, c := range w.crowd() {
		if c == w.roles.mallory || c == w.roles.exFriend || c == w.roles.blockedByAlex {
			continue
		}
		out = append(out, c)
	}
	return out
}
