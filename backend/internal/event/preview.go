package event

import (
	"context"
	"log"
	"regexp"
	"strconv"
	"time"

	db "example.com/music-app/db/sqlc"
	"github.com/jackc/pgx/v5/pgtype"
)

// Deezer signs a preview link for 15 minutes: "...hdnea=exp=1760000000~acl=...".
var previewExpiry = regexp.MustCompile(`exp=(\d+)`)

// withFreshPreview gives the song about to play a preview link that still
// works, so the speaker has something to load: the stored one has expired,
// or there is none (the seed stores none). Asks Deezer for the track again
// and keeps the new link. Best effort: if Deezer fails, the song goes out as
// it was and simply plays silent, as before.
func (s *Service) withFreshPreview(ctx context.Context, song db.Song) db.Song {
	if s.deezer == nil || previewUsable(song.PreviewUrl, time.Now()) {
		return song
	}
	track, err := s.deezer.GetTrack(ctx, strconv.FormatInt(song.DeezerSongID, 10))
	if err != nil || track.GetPreviewUrl() == "" {
		log.Printf("event: no fresh preview for song %d: %v", song.ID, err)
		return song
	}
	song.PreviewUrl = pgtype.Text{String: track.GetPreviewUrl(), Valid: true}
	if err := db.New(s.pool).SetSongPreviewURL(ctx, db.SetSongPreviewURLParams{
		ID: song.ID, PreviewUrl: song.PreviewUrl,
	}); err != nil {
		log.Printf("event: could not store the fresh preview of song %d: %v", song.ID, err)
	}
	return song
}

// previewUsable: a link with at least a minute left, so the client can load
// it before it expires. A link with no expiry in it is taken as good.
func previewUsable(url pgtype.Text, now time.Time) bool {
	if !url.Valid || url.String == "" {
		return false
	}
	m := previewExpiry.FindStringSubmatch(url.String)
	if m == nil {
		return true
	}
	exp, err := strconv.ParseInt(m[1], 10, 64)
	return err == nil && now.Unix() < exp-60
}
