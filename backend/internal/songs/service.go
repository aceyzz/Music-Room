package songs

import (
	"context"
	"errors"
	"strconv"

	sqlc "example.com/music-app/db/sqlc"
	"example.com/music-app/internal/music_provider"
	"github.com/jackc/pgx/v5/pgtype"
)

type Service struct {
	deezer *music_provider.DeezerClient
	q      *sqlc.Queries
}

type FromDeezer struct {
	DeezerSongID    int64
	Title           string
	DurationSeconds int32
	ArtistName      string
	DeezerArtistID  int64
	AlbumTitle      string
	DeezerAlbumID   int64
	CoverURL        string
	PreviewURL      string
}

var ErrNotFound = errors.New("song not found")

func NewService(deezer *music_provider.DeezerClient, db sqlc.DBTX) *Service {
	return &Service{deezer: deezer, q: sqlc.New(db)}
}

func (s *Service) GetSongByDeezerID(ctx context.Context, deezerSongID int64) (sqlc.Song, error) {
	song, err := s.q.GetSongByDeezerID(ctx, deezerSongID)
	if err != nil {
		return sqlc.Song{}, ErrNotFound
	}
	return song, nil
}

func (s *Service) AddSong(ctx context.Context, input FromDeezer) (sqlc.Song, error) {
	// Missing required fields
	if input.DeezerSongID <= 0 || input.Title == "" || input.DurationSeconds <= 0 || input.ArtistName == "" {
		return sqlc.Song{}, errors.New("missing required fields for adding a song")
	}
	// If the song already exists in the database
	existingSong, err := s.q.GetSongByDeezerID(ctx, input.DeezerSongID)
	if err == nil {
		return existingSong, nil
	}
	// If the song doesn't exist, insert it and return the newly created song
	return s.q.UpsertSongFromDeezer(ctx, sqlc.UpsertSongFromDeezerParams{
		DeezerSongID:    input.DeezerSongID,
		Title:           input.Title,
		DurationSeconds: input.DurationSeconds,
		ArtistName:      input.ArtistName,
		DeezerArtistID:  optionalInt8(input.DeezerArtistID),
		AlbumTitle:      input.AlbumTitle,
		DeezerAlbumID:   optionalInt8(input.DeezerAlbumID),
		CoverUrl:        optionalText(input.CoverURL),
		PreviewUrl:      optionalText(input.PreviewURL),
		Readable:        true,
	})
}

func (s *Service) AddSongFromDeezer(ctx context.Context, deezerSongID int64) (sqlc.Song, error) {
	deezerSong, err := s.deezer.GetTrack(ctx, strconv.FormatInt(deezerSongID, 10))
	if err != nil {
		return sqlc.Song{}, err
	}

	return s.AddSong(ctx, FromDeezer{
		DeezerSongID:    deezerSong.GetDeezerSongId(),
		Title:           deezerSong.GetTitle(),
		DurationSeconds: int32(deezerSong.GetDurationSeconds()),
		ArtistName:      deezerSong.GetArtistName(),
		DeezerArtistID:  deezerSong.GetDeezerArtistId(),
		AlbumTitle:      deezerSong.GetAlbumTitle(),
		DeezerAlbumID:   deezerSong.GetDeezerAlbumId(),
		CoverURL:        deezerSong.GetCoverUrl(),
		PreviewURL:      deezerSong.GetPreviewUrl(),
	})
}

func optionalInt8(value int64) pgtype.Int8 {
	return pgtype.Int8{Int64: value, Valid: value > 0}
}

func optionalText(value string) pgtype.Text {
	return pgtype.Text{String: value, Valid: value != ""}
}
