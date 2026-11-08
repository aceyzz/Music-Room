package main

import (
	"fmt"
	"time"
)

// Control grants, sessions, sign-in attempts, one-time codes and the activity
// log: the state no screen lists yet, but that a real database of this age
// would hold, and that the security and audit work (docs/annex/todo.md §6) reads.

func (w *World) buildGrants() {
	summer := w.eventByName("Summer Festival 2026 — 3 Days").Idx
	rooftop := w.eventByName("Rooftop Sessions #13 — Live").Idx
	campfire := w.eventByName("Campfire Night").Idx
	dev := func(owner int, name string) int {
		for _, d := range w.Devices {
			if d.Owner == owner && d.Name == name {
				return d.Idx
			}
		}
		panic("no device " + name)
	}
	// A licence is for one event, never for every one (00021): an event of
	// the device's owner, -1 when they host none, and the grant is left out.
	hostedBy := func(owner int) int {
		for _, e := range w.Events {
			if e.Host == owner {
				return e.Idx
			}
		}
		return -1
	}
	type g = Grant
	grants := []Grant{
		{Device: devAlexSoundbar, Grantee: uSarah, Event: summer,
			Note: "Scoped to Summer Festival: Sarah drives it now"},
		{Device: devAlexPhone, Grantee: uLiam, Event: summer,
			ExpiresAt: ptr(w.in(7 * day)), Note: "Expires in 7 days"},
		{Device: dev(uAlex, "MacBook Air"), Grantee: uEmma, Event: summer,
			ExpiresAt: ptr(w.ago(10 * day)), Note: "Expired 10 days ago"},
		{Device: devAlexSoundbar, Grantee: uGoogle, Event: summer,
			RevokedAt: ptr(w.ago(20 * day)), Note: "Revoked 20 days ago"},
		{Device: devSarahPhone, Grantee: uAlex, Event: rooftop,
			Note: "Sarah lets Alex drive her phone at Rooftop Sessions"},
		{Device: dev(uSarah, "Studio PC"), Grantee: uAlex, Event: rooftop,
			Note: "Scoped to Rooftop Sessions #13"},
		{Device: devLiamPhone, Grantee: uAlex, Event: campfire,
			Note: "Scoped to Campfire Night"},
		{Device: dev(uEmma, "Emma's iPad"), Grantee: uAlex, Event: hostedBy(uEmma),
			RevokedAt: ptr(w.ago(3 * day)), Note: "Revoked by Emma"},
		{Device: dev(uIntra42, "42 iMac e1r2p3"), Grantee: uAlex, Event: hostedBy(uIntra42),
			ExpiresAt: ptr(w.in(2 * day)), Note: "Expires in 2 days"},
		{Device: dev(uSarah, "Chrome on Linux"), Grantee: uLiam, Event: rooftop},
		{Device: dev(uEmma, "Galaxy S24"), Grantee: uSarah, Event: hostedBy(uEmma),
			ExpiresAt: ptr(w.in(30 * day))},
	}
	for i := range grants {
		grants[i].CreatedAt = w.between(w.ago(60*day), w.ago(day))
		if grants[i].RevokedAt != nil && grants[i].CreatedAt.After(*grants[i].RevokedAt) {
			grants[i].CreatedAt = grants[i].RevokedAt.Add(-5 * day)
		}
	}
	// A handful between crowd friends, to make the table non-trivial.
	for _, d := range w.Devices {
		if len(grants) == 18 {
			break
		}
		if d.Owner < firstCrowd || !w.active(d.Owner) {
			continue
		}
		var friend = -1
		for _, f := range w.friendsOf(d.Owner) {
			if f >= firstCrowd && w.active(f) {
				friend = f
				break
			}
		}
		if friend < 0 {
			continue
		}
		gr := g{Device: d.Idx, Grantee: friend, Event: hostedBy(d.Owner),
			CreatedAt: w.between(w.ago(90*day), w.ago(day))}
		if len(grants)%3 == 0 {
			gr.ExpiresAt = ptr(w.in(time.Duration(1+w.rng.IntN(20)) * day))
		}
		grants = append(grants, gr)
	}
	for i := range grants {
		if grants[i].Event < 0 {
			continue // its owner hosts no event to scope it to.
		}
		w.Grants = append(w.Grants, &grants[i])
	}
}

var userAgents = map[string]string{
	"ios":     "MusicRoom/1.4.0 (iPhone; iOS 18.6) grpc-dart/4.0",
	"android": "MusicRoom/1.4.0 (Android 15; Pixel 8) grpc-dart/4.0",
	"desktop": "MusicRoom/1.4.0 (macOS 15.5) grpc-dart/4.0",
	"web":     "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/139.0 Safari/537.36",
}

func (w *World) ip() string {
	return fmt.Sprintf("%d.%d.%d.%d", []int{82, 90, 176, 91, 37, 62}[w.rng.IntN(6)], w.rng.IntN(256), w.rng.IntN(256), 1+w.rng.IntN(254))
}

func (w *World) token() string {
	return fmt.Sprintf("seed-%016x%016x", w.rng.Uint64(), w.rng.Uint64())
}

func (w *World) buildHistory() {
	// --- sessions ---------------------------------------------------------------
	reasons := []string{"logout", "user_revoked", "password_change", "admin", "suspected_theft"}
	for _, u := range w.Users {
		if u.LastLoginAt == nil || !u.HasPassword && len(u.OAuth) == 0 {
			continue
		}
		devices := w.devicesOf(u.Idx)
		session := func(created time.Time) *Session {
			s := &Session{
				PublicID: publicID(kindSession, len(w.Sessions)+1), User: u.Idx, Device: -1,
				Token: w.token(), IP: w.ip(), CreatedAt: created, LastUsed: created,
				ExpiresAt: created.Add(30 * day),
			}
			s.UserAgent = userAgents["web"]
			if len(devices) > 0 {
				s.Device = devices[w.rng.IntN(len(devices))]
				s.UserAgent = userAgents[w.Devices[s.Device].Platform]
			}
			w.Sessions = append(w.Sessions, s)
			return s
		}
		// The session from the last sign-in, still open (unless the account
		// is no longer active, in which case the authenticator refuses it).
		cur := session(*u.LastLoginAt)
		cur.LastUsed = w.between(*u.LastLoginAt, w.ago(minute))
		if cur.LastUsed.Before(w.ago(7 * day)) {
			cur.ExpiresAt = cur.CreatedAt.Add(30 * day) // idle: rejected in Go, still a row
		}
		// Older ones: ended by expiry or revoked for one reason or another.
		if u.CreatedAt.Before(w.ago(40 * day)) {
			for i := 0; i < w.rng.IntN(3); i++ {
				old := session(w.between(u.CreatedAt, w.ago(35*day)))
				old.LastUsed = w.between(old.CreatedAt, old.ExpiresAt)
				if w.rng.IntN(2) == 0 {
					reason := reasons[w.rng.IntN(len(reasons))]
					old.RevokedAt, old.Reason = ptr(old.LastUsed.Add(time.Minute)), reason
				}
			}
		}
	}
	// Alex's dev session, known token (DevSessionToken).
	w.Sessions = append(w.Sessions, &Session{
		PublicID: publicID(kindSession, len(w.Sessions)+1), User: uAlex, Device: devAlexPhone,
		Token: DevSessionToken, UserAgent: userAgents["ios"], IP: "127.0.0.1",
		CreatedAt: w.ago(minute), LastUsed: w.ago(minute), ExpiresAt: w.in(30 * day),
	})
	// One of every revocation reason on Alex's account, for the session list.
	for i, reason := range reasons {
		created := w.ago(time.Duration(50+i*20) * day)
		w.Sessions = append(w.Sessions, &Session{
			PublicID: publicID(kindSession, len(w.Sessions)+1), User: uAlex, Device: -1,
			Token: w.token(), UserAgent: userAgents["web"], IP: w.ip(), CreatedAt: created,
			LastUsed: created.Add(3 * day), ExpiresAt: created.Add(30 * day),
			RevokedAt: ptr(created.Add(3*day + time.Hour)), Reason: reason,
		})
	}

	// --- sign-in attempts ---------------------------------------------------------
	// Failures are all older than the 15-minute lockout window
	// (login.FailureWindow), so no seeded account starts locked.
	for _, s := range w.Sessions {
		u := w.Users[s.User]
		if !u.HasPassword || s.Token == DevSessionToken {
			continue
		}
		w.LoginAttempts = append(w.LoginAttempts, &LoginAttempt{Email: u.Email, IP: s.IP, Succeeded: true, At: s.CreatedAt})
		if w.rng.IntN(4) == 0 && s.CreatedAt.Before(w.ago(hour)) {
			w.LoginAttempts = append(w.LoginAttempts, &LoginAttempt{
				Email: u.Email, IP: s.IP, Reason: "bad_password", At: s.CreatedAt.Add(-time.Minute)})
		}
	}
	for i := 0; i < 25; i++ {
		w.LoginAttempts = append(w.LoginAttempts, &LoginAttempt{
			Email: fmt.Sprintf("nobody%d@%s", i, EmailDomain), IP: w.ip(), Reason: "unknown_email",
			At: w.between(w.ago(90*day), w.ago(2*hour))})
	}
	for _, at := range []time.Duration{20 * day, 3 * day, 2 * hour} {
		w.LoginAttempts = append(w.LoginAttempts,
			&LoginAttempt{Email: w.Users[uSuspended].Email, IP: w.ip(), Reason: "inactive", At: w.ago(at)},
			&LoginAttempt{Email: w.Users[uOAuthOnly].Email, IP: w.ip(), Reason: "no_password", At: w.ago(at + hour)},
		)
	}
	w.LoginAttempts = append(w.LoginAttempts,
		&LoginAttempt{Email: w.Users[uDeleted].Email, IP: w.ip(), Reason: "unknown_email", At: w.ago(10 * day)})
	// A burst against Alex, a week ago: four bad passwords, then the right one.
	for i := 0; i < 4; i++ {
		w.LoginAttempts = append(w.LoginAttempts, &LoginAttempt{Email: w.Users[uAlex].Email, IP: "185.220.101.7",
			Reason: "bad_password", At: w.ago(7*day - time.Duration(i)*time.Minute)})
	}

	// --- one-time codes ---------------------------------------------------------
	for _, u := range w.Users {
		if !u.HasPassword {
			continue
		}
		if u.Verified && w.rng.IntN(2) == 0 || u.Idx < firstCrowd && u.Verified {
			at := u.CreatedAt.Add(time.Minute)
			w.UserTokens = append(w.UserTokens, &UserToken{User: u.Idx, Purpose: "email_verification",
				Code: fmt.Sprintf("%06d", w.rng.IntN(1000000)), ExpiresAt: at.Add(15 * minute),
				Consumed: ptr(at.Add(2 * minute)), Attempts: 1 + w.rng.IntN(2), IP: w.ip(), CreatedAt: at})
		}
	}
	for _, u := range pick(w, w.crowd(), 8) {
		at := w.between(w.Users[u].CreatedAt, w.ago(day))
		t := &UserToken{User: u, Purpose: "password_reset", Code: fmt.Sprintf("%06d", w.rng.IntN(1000000)),
			ExpiresAt: at.Add(15 * minute), IP: w.ip(), CreatedAt: at, Attempts: w.rng.IntN(3)}
		if w.rng.IntN(3) > 0 {
			t.Consumed = ptr(at.Add(4 * minute))
		}
		w.UserTokens = append(w.UserTokens, t)
	}
	// The unverified account's live code. Long-lived on purpose (a real one
	// lasts APP_EMAIL_CODE_TTL_MINUTES), so the demo works days after seeding.
	w.UserTokens = append(w.UserTokens, &UserToken{User: uUnverified, Purpose: "email_verification",
		Code: VerificationCode, ExpiresAt: w.in(30 * day), IP: "127.0.0.1", CreatedAt: w.ago(5 * minute)})

	w.buildActivity()
}

// buildActivity derives the audit log from what happened in the world over the
// last 90 days, so every line matches a row elsewhere.
func (w *World) buildActivity() {
	since := w.ago(90 * day)
	log := func(u, device int, action, kind string, resource int, at time.Time, code int, meta map[string]any) {
		if at.Before(since) || at.After(w.Now) {
			return
		}
		ua, ip := userAgents["web"], "10.0.0.1"
		if device >= 0 {
			ua = userAgents[w.Devices[device].Platform]
		}
		w.ActivityLogs = append(w.ActivityLogs, &ActivityLog{User: u, Device: device, Action: action,
			ResourceType: kind, Resource: resource, ResultCode: code, Metadata: meta, IP: ip, UserAgent: ua, At: at})
	}
	deviceOf := func(u int) int {
		if d := w.devicesOf(u); len(d) > 0 {
			return d[0]
		}
		return -1
	}
	for _, s := range w.Sessions {
		log(s.User, s.Device, "auth.login", "user", s.User, s.CreatedAt, 0, map[string]any{"session": s.PublicID})
		if s.Reason == "logout" {
			log(s.User, s.Device, "auth.logout", "user", s.User, *s.RevokedAt, 0, nil)
		}
	}
	for _, r := range w.FriendRequests {
		log(r.From, deviceOf(r.From), "social.friend_request.send", "user", r.To, r.CreatedAt, 0, nil)
		if r.Responded != nil {
			log(r.To, deviceOf(r.To), "social.friend_request."+r.Status, "user", r.From, *r.Responded, 0, nil)
		}
	}
	for _, b := range w.Blocks {
		log(b.Blocker, deviceOf(b.Blocker), "social.block", "user", b.Blocked, b.At, 0, nil)
	}
	for _, p := range w.Playlists {
		log(p.Owner, deviceOf(p.Owner), "playlist.create", "playlist", p.Idx, p.CreatedAt, 0, map[string]any{"name": p.Name})
		for _, op := range p.Ops {
			log(op.Actor, deviceOf(op.Actor), "playlist."+op.Type, "playlist", p.Idx, op.At, 0,
				map[string]any{"revision": op.Revision})
		}
	}
	for _, e := range w.Events {
		log(e.Host, deviceOf(e.Host), "event.create", "event", e.Idx, e.CreatedAt, 0, map[string]any{"name": e.Name})
		for _, q := range e.Entries {
			if q.SuggestedBy >= 0 {
				log(q.SuggestedBy, deviceOf(q.SuggestedBy), "event.song.suggest", "event", e.Idx, q.CreatedAt, 0,
					map[string]any{"queue_entry": q.PublicID})
			}
			for i, v := range q.Votes {
				if i%3 == 0 { // one vote in three: the log samples, the votes table is exhaustive
					log(v.User, deviceOf(v.User), "event.vote.cast", "event", e.Idx, v.At, 0,
						map[string]any{"queue_entry": q.PublicID})
				}
			}
		}
		// Votes the app sent from far away: refused (PERMISSION_DENIED = 7).
		if e.License == "location_time" && e.StartsAt != nil {
			log(uAlex, devAlexPhone, "event.vote.cast", "event", e.Idx, e.StartsAt.Add(20*minute), 7,
				map[string]any{"reason": "outside venue radius"})
		}
	}
	for _, d := range w.Devices {
		log(d.Owner, d.Idx, "device.register", "", -1, d.CreatedAt, 0, map[string]any{"device": d.PublicID})
	}
}
