package music_provider

import (
	"context"

	pb "example.com/music-app/gen/go/music_room/v1"
)

type Service struct {
	pb.UnimplementedMusicProviderServiceServer
	deezer *DeezerClient
}

func NewService(deezer *DeezerClient) *Service {
	if deezer == nil {
		deezer = NewDeezerClient()
	}
	return &Service{
		deezer: deezer,
	}
}

func (s *Service) GetSong(ctx context.Context, req *pb.GetSongRequest) (*pb.GetSongResponse, error) {
	track, err := s.deezer.GetTrack(ctx, req.GetId())
	if err != nil {
		return nil, err
	}
	return &pb.GetSongResponse{Song: track}, nil
}

func (s *Service) SearchSongs(ctx context.Context, req *pb.SearchSongsRequest) (*pb.SearchSongsResponse, error) {
	songs, err := s.deezer.SearchTracks(ctx, req.GetQuery())
	if err != nil {
		return nil, err
	}
	return &pb.SearchSongsResponse{Songs: songs}, nil
}
