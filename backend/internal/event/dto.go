package event

import (
	"errors"
	"strconv"
	"time"

	db "example.com/music-app/db/sqlc"
	pb "example.com/music-app/gen/go/music_room/v1"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func songDTO(song db.Song) *pb.SongDTO {
	return &pb.SongDTO{
		Id: song.ID, DeezerSongId: song.DeezerSongID, Title: song.Title,
		DurationSeconds: int64(song.DurationSeconds), ArtistName: song.ArtistName,
		DeezerArtistId: song.DeezerArtistID.Int64, AlbumTitle: song.AlbumTitle,
		DeezerAlbumId: song.DeezerAlbumID.Int64, CoverUrl: song.CoverUrl.String,
		PreviewUrl: song.PreviewUrl.String,
	}
}

func eventDTO(e db.Event) *pb.MusicEventDTO {
	return &pb.MusicEventDTO{
		Id: e.ID, PublicId: e.PublicID.String(), HostId: e.HostID,
		SourcePlaylistId: e.SourcePlaylistID.Int64, Name: e.Name, Description: e.Description.String,
		Visibility: string(e.Visibility), VoteLicense: string(e.VoteLicense), Status: string(e.Status),
		Revision: e.Revision, CreatedAt: e.CreatedAt.Time.Unix(), UpdatedAt: e.UpdatedAt.Time.Unix(),
		StartsAt: unixOrZero(e.StartsAt), EndsAt: unixOrZero(e.EndsAt), DeletedAt: unixOrZero(e.DeletedAt),
		VenueLatitude: numericOrZero(e.VenueLatitude), VenueLongitude: numericOrZero(e.VenueLongitude),
		VenueRadiusMeters: e.VenueRadiusMeters.Int32,
	}
}

// numericOrZero lit une colonne NUMERIC nullable (venue_latitude/longitude),
// 0 quand elle est vide.
func numericOrZero(n pgtype.Numeric) float64 {
	f, err := n.Float64Value()
	if err != nil || !f.Valid {
		return 0
	}
	return f.Float64
}

func validVisibility(value string) (string, error) {
	if value == "" {
		return "public", nil
	}
	if value != "public" && value != "private" {
		return "", status.Error(codes.InvalidArgument, "visibility must be public or private")
	}
	return value, nil
}

func validVoteLicense(value string) (string, error) {
	if value == "" {
		return "everyone", nil
	}
	if value != "everyone" && value != "invited_only" && value != "location_time" {
		return "", status.Error(codes.InvalidArgument, "vote_license must be everyone, invited_only or location_time")
	}
	return value, nil
}

// optionalNumeric convertit une coordonnée facultative en pgtype.Numeric.
// 0 est traité comme "non fourni", par cohérence avec le reste du code
// (added_by_id, source_playlist_id, ...).
func optionalNumeric(value float64) pgtype.Numeric {
	var n pgtype.Numeric
	if value == 0 {
		return n
	}
	_ = n.Scan(strconv.FormatFloat(value, 'f', 6, 64))
	return n
}

// parseVoteWindowTime convertit une heure "HH:MM" (créneau de vote,
// vote_window_start/end) en pgtype.Time. Chaîne vide = non fourni.
func parseVoteWindowTime(value string) (pgtype.Time, error) {
	if value == "" {
		return pgtype.Time{}, nil
	}
	t, err := time.Parse("15:04", value)
	if err != nil {
		return pgtype.Time{}, status.Error(codes.InvalidArgument, `vote_window_start and vote_window_end must be "HH:MM"`)
	}
	micros := (time.Duration(t.Hour())*time.Hour + time.Duration(t.Minute())*time.Minute).Microseconds()
	return pgtype.Time{Microseconds: micros, Valid: true}, nil
}

// eventWindow valide et convertit les horaires prévus d'un événement
// (starts_at/ends_at, secondes unix). Les deux sont obligatoires : un
// événement est une soirée qui a un moment, et l'app le classe en passé / en
// cours / à venir avec.
// La fin doit suivre le début -- vérifié ici plutôt que de laisser la
// contrainte events_window_check remonter en Internal -- et ne pas être déjà
// passée. Un début dans le passé est accepté, pour un événement qui commence
// tout de suite.
func eventWindow(startsAt, endsAt int64, now time.Time) (pgtype.Timestamptz, pgtype.Timestamptz, error) {
	if startsAt == 0 || endsAt == 0 {
		return pgtype.Timestamptz{}, pgtype.Timestamptz{},
			status.Error(codes.InvalidArgument, "starts_at and ends_at are required")
	}
	if endsAt <= startsAt {
		return pgtype.Timestamptz{}, pgtype.Timestamptz{},
			status.Error(codes.InvalidArgument, "ends_at must be after starts_at")
	}
	if endsAt <= now.Unix() {
		return pgtype.Timestamptz{}, pgtype.Timestamptz{},
			status.Error(codes.InvalidArgument, "ends_at must be in the future")
	}
	return pgtype.Timestamptz{Time: time.Unix(startsAt, 0).UTC(), Valid: true},
		pgtype.Timestamptz{Time: time.Unix(endsAt, 0).UTC(), Valid: true}, nil
}

func databaseError(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return status.Error(codes.NotFound, "event or queue entry not found")
	}
	return status.Error(codes.Internal, "event database operation failed")
}
