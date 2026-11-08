package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strconv"
	"strings"
	"sync"
	"time"

	sqlc "example.com/music-app/db/sqlc"
	"example.com/music-app/internal/authz"
	"example.com/music-app/internal/authz/outbox"
	"example.com/music-app/internal/media"
	"example.com/music-app/internal/music_provider"
	"example.com/music-app/internal/security"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// Writing the world: plain INSERTs in one transaction, and the permission
// tuples through the outbox ON THAT TRANSACTION (outbox.InTx), exactly as the
// handlers do it. The repositories are not used because they cannot write what
// a credible world needs -- fixed public ids, backdated timestamps, events.status,
// played and skipped history, invitations, expired grants, revoked sessions --
// but the tuples come from the same builders (internal/authz), which is the part
// that must not drift: a row without its tuple is invisible to every Check.
//
// Ids are reserved from each table's sequence (nextval) rather than written as
// constants, so seeding next to existing rows cannot collide with them, and the
// sequences stay ahead of every id in the table.

// ids maps world indices to database ids, per table.
type ids struct {
	users, images, requests, playlists, rows, events, entries, devices []int64
	songs                                                              []int64
}

func reserve(ctx context.Context, tx pgx.Tx, table string, n int) ([]int64, error) {
	if n == 0 {
		return nil, nil
	}
	rows, err := tx.Query(ctx,
		"SELECT nextval(pg_get_serial_sequence($1, 'id')) FROM generate_series(1, $2)", table, n)
	if err != nil {
		return nil, fmt.Errorf("reserve %s ids: %w", table, err)
	}
	return pgx.CollectRows(rows, pgx.RowTo[int64])
}

// inserter batches INSERTs. A column written "name:type" gets a $n::text::type
// placeholder, so enums, citext, inet, numeric, date, time and jsonb can all
// travel as Go strings without registering their types with pgx.
type inserter struct {
	ctx    context.Context
	tx     pgx.Tx
	batch  pgx.Batch
	labels []string
	sql    map[string]string
	count  map[string]int
}

func newInserter(ctx context.Context, tx pgx.Tx) *inserter {
	return &inserter{ctx: ctx, tx: tx, sql: map[string]string{}, count: map[string]int{}}
}

func (in *inserter) add(table, columns string, values ...any) {
	key := table + "|" + columns
	stmt, ok := in.sql[key]
	if !ok {
		cols := strings.Split(columns, ",")
		names := make([]string, len(cols))
		holders := make([]string, len(cols))
		for i, c := range cols {
			name, typ, typed := strings.Cut(strings.TrimSpace(c), ":")
			names[i] = name
			holders[i] = "$" + strconv.Itoa(i+1)
			if typed {
				holders[i] += "::text::" + typ
			}
		}
		stmt = fmt.Sprintf("INSERT INTO %s (%s) VALUES (%s)", table, strings.Join(names, ", "), strings.Join(holders, ", "))
		in.sql[key] = stmt
	}
	if strings.Count(columns, ",")+1 != len(values) {
		panic(fmt.Sprintf("%s: %d columns, %d values", table, strings.Count(columns, ",")+1, len(values)))
	}
	in.batch.Queue(stmt, values...)
	in.labels = append(in.labels, table)
	in.count[table]++
	if in.batch.Len() >= 1000 {
		if err := in.flush(); err != nil {
			panic(err) // recovered in writeWorld
		}
	}
}

func (in *inserter) flush() error {
	if in.batch.Len() == 0 {
		return nil
	}
	results := in.tx.SendBatch(in.ctx, &in.batch)
	for i := 0; i < in.batch.Len(); i++ {
		if _, err := results.Exec(); err != nil {
			_ = results.Close()
			return fmt.Errorf("insert into %s: %w", in.labels[i], err)
		}
	}
	in.batch = pgx.Batch{}
	in.labels = in.labels[:0]
	return results.Close()
}

// Helpers turning optional world values into SQL NULLs.

func text(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func at(t *time.Time) any {
	if t == nil {
		return nil
	}
	return *t
}

func ref(list []int64, i int) any {
	if i < 0 {
		return nil
	}
	return list[i]
}

func jsonText(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return string(b)
}

func uuid(s string) pgtype.UUID {
	var u pgtype.UUID
	if err := u.Scan(s); err != nil {
		panic(err)
	}
	return u
}

func hash(token string) []byte { return security.HashSessionToken(token) }

// refreshSongs fetches each track from Deezer for a fresh preview URL (they are
// signed and expire). Failures leave the preview empty: the app still lists the
// song, it just cannot play it. Three failures in a row mean Deezer is not
// reachable, and the rest is skipped rather than waited on.
func refreshSongs(ctx context.Context, w *World) (fetched int) {
	client := music_provider.NewDeezerClient()
	var mu sync.Mutex
	var wg sync.WaitGroup
	failures := 0
	sem := make(chan struct{}, 4)
	for _, s := range w.Songs {
		mu.Lock()
		stop := failures >= 3 && fetched == 0
		mu.Unlock()
		if stop {
			break
		}
		wg.Add(1)
		sem <- struct{}{}
		go func(s *Song) {
			defer wg.Done()
			defer func() { <-sem }()
			cctx, cancel := context.WithTimeout(ctx, 8*time.Second)
			defer cancel()
			track, err := client.GetTrack(cctx, strconv.FormatInt(s.DeezerID, 10))
			mu.Lock()
			defer mu.Unlock()
			if err != nil || track.GetPreviewUrl() == "" {
				failures++
				return
			}
			s.PreviewURL = track.GetPreviewUrl()
			fetched++
		}(s)
		// Deezer allows 50 requests per 5 seconds.
		time.Sleep(110 * time.Millisecond)
	}
	wg.Wait()
	return fetched
}

// saveImages draws and stores every picture. Before the transaction: a failed
// transaction leaves orphan files (harmless, -reset removes them), while files
// written after a commit could fail and leave rows pointing at nothing.
func saveImages(w *World, store *media.Store) (sizes map[string][3]int, err error) {
	sizes = map[string][3]int{}
	var mu sync.Mutex
	var wg sync.WaitGroup
	errs := make(chan error, len(w.Images))
	sem := make(chan struct{}, 8)
	for _, img := range w.Images {
		wg.Add(1)
		sem <- struct{}{}
		go func(img *Image) {
			defer wg.Done()
			defer func() { <-sem }()
			for _, v := range []struct {
				key  string
				size int
			}{{img.OrigKey, originalSize}, {img.ThumbKey, thumbSize}} {
				data := renderImage(img.Seed, img.Kind, v.size)
				if err := store.Save(v.key, data); err != nil {
					errs <- err
					return
				}
				mu.Lock()
				sizes[v.key] = [3]int{v.size, v.size, len(data)}
				mu.Unlock()
			}
		}(img)
	}
	wg.Wait()
	close(errs)
	if err := <-errs; err != nil {
		return nil, fmt.Errorf("save image: %w", err)
	}
	return sizes, nil
}

func writeWorld(ctx context.Context, db outbox.DB, ob *outbox.Outbox, w *World, sizes map[string][3]int) (counts map[string]int, changes int, err error) {
	counts, err = outbox.InTx(ctx, ob, db, func(ctx context.Context, tx pgx.Tx) (counts map[string]int, out []authz.Change, err error) {
		defer func() {
			if r := recover(); r != nil {
				err = fmt.Errorf("%v", r)
			}
		}()
		out, counts, err = insertAll(ctx, tx, w, sizes)
		changes = len(out)
		return counts, out, err
	})
	return counts, changes, err
}

func insertAll(ctx context.Context, tx pgx.Tx, w *World, sizes map[string][3]int) ([]authz.Change, map[string]int, error) {
	var id ids
	var err error
	var rowsTotal int
	for _, p := range w.Playlists {
		rowsTotal += len(p.AllRows)
	}
	for _, r := range []struct {
		table string
		n     int
		dst   *[]int64
	}{
		{"users", len(w.Users), &id.users},
		{"images", 2 * len(w.Images), &id.images},
		{"friend_requests", len(w.FriendRequests), &id.requests},
		{"playlists", len(w.Playlists), &id.playlists},
		{"playlist_songs", rowsTotal, &id.rows},
		{"events", len(w.Events), &id.events},
		{"event_queue_entries", w.entriesCreated, &id.entries},
		{"devices", len(w.Devices), &id.devices},
	} {
		if *r.dst, err = reserve(ctx, tx, r.table, r.n); err != nil {
			return nil, nil, err
		}
	}

	// Songs first, one by one: the cache may already hold some of them
	// (deezer_song_id is unique), so the id comes back from the upsert.
	q := sqlc.New(tx)
	for _, s := range w.Songs {
		song, err := q.UpsertSongFromDeezer(ctx, sqlc.UpsertSongFromDeezerParams{
			DeezerSongID: s.DeezerID, Title: s.Title, DurationSeconds: int32(s.Duration()),
			ArtistName: s.Artist, DeezerArtistID: pgtype.Int8{Int64: s.ArtistID, Valid: s.ArtistID > 0},
			AlbumTitle: s.Album, DeezerAlbumID: pgtype.Int8{Int64: s.AlbumID, Valid: s.AlbumID > 0},
			CoverUrl:       pgtype.Text{String: s.CoverURL, Valid: s.CoverURL != ""},
			PreviewUrl:     pgtype.Text{String: s.PreviewURL, Valid: s.PreviewURL != ""},
			DeezerLink:     pgtype.Text{String: s.Link, Valid: s.Link != ""},
			ExplicitLyrics: s.Explicit, Readable: true, Rank: s.Rank,
		})
		if err != nil {
			return nil, nil, fmt.Errorf("song %d: %w", s.DeezerID, err)
		}
		id.songs = append(id.songs, song.ID)
	}

	in := newInserter(ctx, tx)
	var changes []authz.Change
	password, err := security.NewArgon2Hasher().Hash(Password)
	if err != nil {
		return nil, nil, err
	}

	// --- users, images, profiles ---------------------------------------------
	for _, u := range w.Users {
		var hashValue any
		if u.HasPassword {
			hashValue = password // one hash for everyone: Verify reads the salt from it
		}
		var verified any
		if u.Verified {
			verified = u.CreatedAt.Add(3 * time.Minute)
		}
		in.add("users", "id, public_id:uuid, display_name, email:citext, password_hash, status:user_status, email_verified_at, last_login_at, created_at, updated_at",
			id.users[u.Idx], u.PublicID, u.DisplayName, u.Email, hashValue, u.Status, verified, at(u.LastLoginAt), u.CreatedAt, u.CreatedAt)
		changes = append(changes, authz.NewUser(u.PublicID))
	}
	for _, img := range w.Images {
		owner := w.Users[img.Owner]
		orig, thumb := id.images[2*img.Idx], id.images[2*img.Idx+1]
		for _, v := range []struct {
			id      int64
			key     string
			variant string
			source  any
			public  string
		}{{orig, img.OrigKey, "original", nil, img.OrigPublicID}, {thumb, img.ThumbKey, "thumb", orig, img.ThumbPublicID}} {
			sz := sizes[v.key]
			in.add("images", "id, owner_user_id, storage_key, content_type, width, height, byte_size, variant, source_image_id, created_at, public_id:uuid",
				v.id, id.users[owner.Idx], v.key, "image/png", sz[0], sz[1], sz[2], v.variant, v.source, img.CreatedAt, v.public)
		}
		attachment := authz.AvatarAttachment()
		origin := authz.OriginAvatarUpload
		if img.Kind == "cover" {
			attachment, origin = authz.PlaylistCoverAttachment(img.PlaylistPublic), authz.OriginPlaylistCover
		}
		changes = append(changes, media.NewImagePair(
			sqlc.Image{PublicID: uuid(img.OrigPublicID)}, sqlc.Image{PublicID: uuid(img.ThumbPublicID)},
			owner.PublicID, attachment, origin)...)
	}
	for _, u := range w.Users {
		p := u.Profile
		var avatar any
		if u.Avatar != nil {
			avatar = id.images[2*u.Avatar.Idx+1] // the profile points at the thumbnail
		}
		v := p.Visibility
		in.add("user_profiles", "user_id, first_name, last_name, bio, birth_date:date, city, country_code, phone_number, avatar_image_id, "+
			"first_name_visibility:visibility_scope, last_name_visibility:visibility_scope, bio_visibility:visibility_scope, "+
			"birth_date_visibility:visibility_scope, location_visibility:visibility_scope, phone_visibility:visibility_scope, "+
			"preferences_visibility:visibility_scope, created_at, updated_at",
			id.users[u.Idx], text(p.FirstName), text(p.LastName), text(p.Bio), text(p.BirthDate), text(p.City), text(p.Country),
			text(p.Phone), avatar,
			v[0], v[1], v[2], v[3], v[4], v[5], v[6], u.CreatedAt, u.CreatedAt)
		for _, o := range u.OAuth {
			in.add("user_oauth_accounts", "user_id, provider:oauth_provider, provider_user_id, provider_email:citext, linked_at",
				id.users[u.Idx], o.Provider, o.ProviderUserID, u.Email, u.CreatedAt)
		}
		for _, pr := range u.Prefs {
			in.add("user_music_preferences", "user_id, deezer_genre_id, genre_name, weight, created_at",
				id.users[u.Idx], pr.GenreID, pr.Genre, pr.Weight, u.CreatedAt.Add(time.Hour))
		}
	}

	// --- social --------------------------------------------------------------
	for _, r := range w.FriendRequests {
		in.add("friend_requests", "id, requester_id, addressee_id, status:friend_request_status, message, responded_at, created_at",
			id.requests[r.Idx], id.users[r.From], id.users[r.To], r.Status, text(r.Message), at(r.Responded), r.CreatedAt)
	}
	for _, f := range w.Friendships {
		a, b := id.users[f.A], id.users[f.B]
		if a > b {
			a, b = b, a
		}
		var from any
		if f.FromRequest != nil {
			from = id.requests[f.FromRequest.Idx]
		}
		in.add("friendships", "user_a_id, user_b_id, created_from_request_id, created_at", a, b, from, f.Since)
	}
	for _, b := range w.Blocks {
		in.add("user_blocks", "blocker_id, blocked_id, created_at", id.users[b.Blocker], id.users[b.Blocked], b.At)
		changes = append(changes, authz.Block(w.Users[b.Blocker].PublicID, w.Users[b.Blocked].PublicID))
	}

	// --- playlists -----------------------------------------------------------
	for _, p := range w.Playlists {
		var cover any
		if p.Cover != nil {
			cover = id.images[2*p.Cover.Idx+1]
		}
		duration := 0
		for _, r := range p.Rows {
			duration += w.Songs[r.Song].Duration()
		}
		updated := p.CreatedAt
		if n := len(p.Ops); n > 0 {
			updated = p.Ops[n-1].At
		}
		in.add("playlists", "id, public_id:uuid, owner_id, name, description, cover_image_id, visibility:resource_visibility, "+
			"edit_license:edit_license, revision, song_count, total_duration_seconds, deleted_at, created_at, updated_at",
			id.playlists[p.Idx], p.PublicID, id.users[p.Owner], p.Name, text(p.Description), cover, p.Visibility,
			p.License, len(p.Ops), len(p.Rows), duration, at(p.DeletedAt), p.CreatedAt, updated)
		changes = append(changes, authz.NewPlaylist(p.PublicID, w.Users[p.Owner].PublicID,
			authz.Visibility(p.Visibility), authz.EditLicense(p.License)))
		for _, m := range p.Members {
			in.add("playlist_members", "playlist_id, user_id, role:member_role, invited_by_id, joined_at",
				id.playlists[p.Idx], id.users[m.User], m.Role, ref(id.users, m.InvitedBy), m.Joined)
			if m.Role != "owner" {
				changes = append(changes, authz.PlaylistMember(p.PublicID, w.Users[m.User].PublicID, authz.MemberRole(m.Role)))
			}
		}
		for _, inv := range p.Invitations {
			in.add("playlist_invitations", "playlist_id, invitee_user_id, invited_by_id, offered_role:member_role, status:invitation_status, expires_at, responded_at, created_at",
				id.playlists[p.Idx], id.users[inv.Invitee], id.users[inv.InvitedBy], inv.Role, inv.Status,
				at(inv.ExpiresAt), at(inv.Responded), inv.CreatedAt)
		}
		for _, r := range p.Rows {
			in.add("playlist_songs", "id, playlist_id, song_id, position:numeric, added_by_id, created_at",
				id.rows[r.Idx], id.playlists[p.Idx], id.songs[r.Song], decimal(r.Position), id.users[r.AddedBy], r.AddedAt)
		}
		for _, op := range p.Ops {
			payload := map[string]any{"playlist_song_id": id.rows[op.Row.Idx]}
			switch op.Type {
			case "add_song":
				payload["song_id"] = id.songs[op.Row.Song]
			case "move_song":
				payload["after_playlist_song_id"] = int64(0)
				if op.After != nil {
					payload["after_playlist_song_id"] = id.rows[op.After.Idx]
				}
			}
			in.add("playlist_ops", "playlist_id, revision, actor_id, op_type:playlist_op_type, payload:jsonb, created_at",
				id.playlists[p.Idx], op.Revision, id.users[op.Actor], op.Type, jsonText(payload), op.At)
		}
	}

	// --- devices -------------------------------------------------------------
	for _, d := range w.Devices {
		in.add("devices", "id, public_id:uuid, user_id, device_identifier, name, platform:device_platform, model, os_version, app_version, last_seen_at, is_active, created_at",
			id.devices[d.Idx], d.PublicID, id.users[d.Owner], d.Identifier, d.Name, d.Platform, d.Model, d.OSVersion,
			d.AppVersion, d.LastSeen, d.Active, d.CreatedAt)
		changes = append(changes, authz.NewDevice(d.PublicID, w.Users[d.Owner].PublicID))
	}

	// --- events --------------------------------------------------------------
	for _, e := range w.Events {
		var lat, lng, radius, wStart, wEnd, tz any
		var window *authz.VoteWindow
		if v := e.Venue; v != nil {
			lat, lng, radius = fmt.Sprintf("%.6f", v.Lat), fmt.Sprintf("%.6f", v.Lng), v.RadiusMeters
			wStart = fmt.Sprintf("%02d:%02d", v.WindowStart/60, v.WindowStart%60)
			wEnd = fmt.Sprintf("%02d:%02d", v.WindowEnd/60, v.WindowEnd%60)
			tz = v.TimeZone
			window = &authz.VoteWindow{StartMinutes: v.WindowStart, EndMinutes: v.WindowEnd, Timezone: v.TimeZone}
		}
		in.add("events", "id, public_id:uuid, host_id, source_playlist_id, name, description, visibility:resource_visibility, "+
			"vote_license:vote_license, status:event_status, starts_at, ends_at, venue_latitude:numeric, venue_longitude:numeric, "+
			"venue_radius_meters, vote_window_start:time, vote_window_end:time, vote_window_timezone, deleted_at, created_at, updated_at",
			id.events[e.Idx], e.PublicID, id.users[e.Host], ref(id.playlists, e.SourcePlaylist), e.Name, text(e.Description),
			e.Visibility, e.License, e.Status, at(e.StartsAt), at(e.EndsAt), lat, lng, radius, wStart, wEnd, tz,
			at(e.DeletedAt), e.CreatedAt, e.CreatedAt)
		changes = append(changes, authz.NewEvent(e.PublicID, w.Users[e.Host].PublicID,
			authz.Visibility(e.Visibility), authz.VoteLicense(e.License), window))
		for _, m := range e.Members {
			in.add("event_members", "event_id, user_id, role:member_role, invited_by_id, joined_at, last_seen_at",
				id.events[e.Idx], id.users[m.User], m.Role, ref(id.users, m.InvitedBy), m.Joined, nil)
			if m.Role != "owner" {
				changes = append(changes, authz.EventMember(e.PublicID, w.Users[m.User].PublicID, authz.MemberRole(m.Role)))
			}
		}
		for _, inv := range e.Invitations {
			in.add("event_invitations", "event_id, invitee_user_id, invited_by_id, status:invitation_status, expires_at, responded_at, created_at",
				id.events[e.Idx], id.users[inv.Invitee], id.users[inv.InvitedBy], inv.Status, at(inv.ExpiresAt), at(inv.Responded), inv.CreatedAt)
		}
		for _, qe := range e.Entries {
			in.add("event_queue_entries", "id, public_id:uuid, event_id, song_id, suggested_by_id, status:queue_entry_status, vote_count, score_reached_at, played_at, created_at",
				id.entries[qe.Idx], qe.PublicID, id.events[e.Idx], id.songs[qe.Song], ref(id.users, qe.SuggestedBy), qe.Status,
				len(qe.Votes), qe.ScoreReachedAt(), at(qe.PlayedAt), qe.CreatedAt)
			suggester := ""
			if qe.SuggestedBy >= 0 {
				suggester = w.Users[qe.SuggestedBy].PublicID
			}
			changes = append(changes, authz.NewQueueEntry(qe.PublicID, e.PublicID, suggester))
			for _, v := range qe.Votes {
				var vlat, vlng any
				if v.Lat != nil {
					vlat, vlng = fmt.Sprintf("%.6f", *v.Lat), fmt.Sprintf("%.6f", *v.Lng)
				}
				in.add("event_queue_votes", "queue_entry_id, user_id, voter_latitude:numeric, voter_longitude:numeric, created_at",
					id.entries[qe.Idx], id.users[v.User], vlat, vlng, v.At)
			}
		}
		pb := e.Playback
		var current any
		if pb.Current != nil {
			current = id.entries[pb.Current.Idx]
		}
		var speaker any
		if pb.Speaker != nil {
			speaker = id.devices[*pb.Speaker]
		}
		in.add("event_playback_states", "event_id, current_entry_id, controller_user_id, controller_device_id, speaker_device_id, is_paused, position_ms, started_at, created_at, updated_at",
			id.events[e.Idx], current, ref(id.users, pb.ControllerUser), ref(id.devices, pb.ControllerDevice),
			speaker, pb.Paused, pb.PositionMs, at(pb.StartedAt), e.CreatedAt, pb.UpdatedAt)
	}

	// --- delegation ----------------------------------------------------------
	for _, g := range w.Grants {
		d := w.Devices[g.Device]
		in.add("device_control_licenses", "device_id, grantee_user_id, granted_by_id, event_id, expires_at, revoked_at, created_at",
			id.devices[g.Device], id.users[g.Grantee], id.users[d.Owner], ref(id.events, g.Event),
			at(g.ExpiresAt), at(g.RevokedAt), g.CreatedAt)
	}

	// --- auth and audit ------------------------------------------------------
	for _, s := range w.Sessions {
		in.add("user_sessions", "public_id:uuid, user_id, device_id, token_hash, user_agent, ip_address:inet, expires_at, last_used_at, revoked_at, revoked_reason:session_revoked_reason, created_at",
			s.PublicID, id.users[s.User], ref(id.devices, s.Device), hash(s.Token), s.UserAgent, s.IP, s.ExpiresAt,
			s.LastUsed, at(s.RevokedAt), text(s.Reason), s.CreatedAt)
	}
	for _, a := range w.LoginAttempts {
		in.add("login_attempts", "email:citext, ip_address:inet, succeeded, failure_reason, created_at",
			a.Email, a.IP, a.Succeeded, text(a.Reason), a.At)
	}
	for _, t := range w.UserTokens {
		in.add("user_tokens", "user_id, purpose:token_purpose, token_hash, expires_at, consumed_at, requested_ip:inet, attempts, created_at",
			id.users[t.User], t.Purpose, hash(t.Code), t.ExpiresAt, at(t.Consumed), t.IP, t.Attempts, t.CreatedAt)
	}
	for _, l := range w.ActivityLogs {
		var resource any
		switch l.ResourceType {
		case "playlist":
			resource = id.playlists[l.Resource]
		case "event":
			resource = id.events[l.Resource]
		case "user":
			resource = id.users[l.Resource]
		}
		var platform, version any
		if l.Device >= 0 {
			platform, version = w.Devices[l.Device].Platform, w.Devices[l.Device].AppVersion
		}
		in.add("activity_logs", "user_id, device_id, action, resource_type, resource_id, platform_snapshot, app_version_snapshot, ip_address:inet, user_agent, result_code, metadata:jsonb, created_at",
			id.users[l.User], ref(id.devices, l.Device), l.Action, text(l.ResourceType), resource, platform, version,
			l.IP, l.UserAgent, l.ResultCode, jsonText(orEmpty(l.Metadata)), l.At)
	}

	if err := in.flush(); err != nil {
		return nil, nil, err
	}
	log.Printf("seed: %d rows written, %d permission changes queued", sum(in.count), len(changes))
	return changes, in.count, nil
}

func orEmpty(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	return m
}

func sum(m map[string]int) int {
	n := 0
	for _, v := range m {
		n += v
	}
	return n
}
