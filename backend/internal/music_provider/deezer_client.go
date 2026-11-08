package music_provider

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	pb "example.com/music-app/gen/go/music_room/v1"
)

// DeezerClient is a thin wrapper around Deezer's public API.
// It holds the base URL and HTTP client used for every request.
type DeezerClient struct {
	baseURL string
	client  *http.Client
}

// -----------------------------------------------------------------------------
// Internal structs used only to unmarshal the raw JSON responses
// returned by the Deezer API. They are NOT exposed outside this package;
// they get converted into the protobuf DTOs (pb.SongDTO, pb.PlaylistDTO)
// via the "map..." functions below.

type deezerArtist struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

type deezerAlbum struct {
	ID          int64  `json:"id"`
	Title       string `json:"title"`
	CoverMedium string `json:"cover_medium"`
	CoverBig    string `json:"cover_big"`
}

type deezerTrack struct {
	ID       int64        `json:"id"`
	Title    string       `json:"title"`
	Duration int          `json:"duration"` // duration in seconds, as returned by the API
	Preview  string       `json:"preview"`  // 30-second preview URL
	Artist   deezerArtist `json:"artist"`
	Album    deezerAlbum  `json:"album"`
}

// deezerAPIErrorResponse mirrors the error format returned by Deezer when a
// request fails at the business level (e.g. unknown user, quota exceeded...).
// Deezer often returns an HTTP 200 status even on failure, which is why
// this field is checked manually inside doGet.
type deezerAPIErrorResponse struct {
	Error struct {
		Type    string `json:"type"`
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

type deezerSearchResponse struct {
	Data []deezerTrack `json:"data"`
}

// NewDeezerClient creates a ready-to-use client pointing at Deezer's
// official public API.
func NewDeezerClient() *DeezerClient {
	baseURL := "https://api.deezer.com"
	return &DeezerClient{
		baseURL: baseURL,
		// A bound, not a tuning: SuggestSong and AddSongToPlaylist call Deezer
		// for a song not yet in `songs`, AddSong inside its transaction, so
		// without one a hung Deezer holds a pool connection (and the request)
		// for as long as the TCP stack allows. The callers' contexts carry no
		// deadline of their own. Found while sizing the V.7 load test.
		client: &http.Client{Timeout: 5 * time.Second},
	}
}

// GetTrack fetches the details of a track by its Deezer ID and converts it
// into a pb.SongDTO.
func (c *DeezerClient) GetTrack(ctx context.Context, trackID string) (*pb.SongDTO, error) {
	if strings.TrimSpace(trackID) == "" {
		return nil, fmt.Errorf("track ID cannot be empty")
	}

	var track deezerTrack
	// url.PathEscape guards against special characters in the ID.
	if err := c.doGet(ctx, fmt.Sprintf("/track/%s", url.PathEscape(trackID)), &track); err != nil {
		return nil, err
	}

	return c.mapTrack(&track), nil
}

// SearchTracks searches for tracks matching the given query string and
// converts the results into a slice of pb.SongDTOs.
func (c *DeezerClient) SearchTracks(ctx context.Context, query string) ([]*pb.SongDTO, error) {
	if strings.TrimSpace(query) == "" {
		return []*pb.SongDTO{}, nil
	}

	var resp deezerSearchResponse
	if err := c.doGet(ctx, fmt.Sprintf("/search?q=%s", url.QueryEscape(query)), &resp); err != nil {
		return nil, err
	}

	return c.mapTracks(resp.Data), nil
}

// doGet is the generic method used by all calls above to:
//  1. build the full URL (baseURL + endpoint)
//  2. execute a GET request using the given context (cancellation/timeout)
//  3. read the response body
//  4. detect API-level errors (even on an HTTP 200, Deezer can return an
//     "error" object in the JSON body)
//  5. unmarshal the JSON into "target" (passed by pointer)
func (c *DeezerClient) doGet(ctx context.Context, endpoint string, target any) error {
	endpoint = strings.TrimSpace(endpoint)
	if !strings.HasPrefix(endpoint, "/") {
		endpoint = "/" + endpoint
	}

	base, err := url.Parse(c.baseURL)
	if err != nil {
		return fmt.Errorf("invalid deezer base URL: %w", err)
	}

	rel, err := url.Parse(endpoint)
	if err != nil {
		return fmt.Errorf("invalid deezer endpoint: %w", err)
	}

	u := base.ResolveReference(rel).String()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return fmt.Errorf("failed to build deezer request: %w", err)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := c.client.Do(req)
	if err != nil {
		return fmt.Errorf("deezer request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("failed to read deezer response: %w", err)
	}

	// Deezer can return a non-200 HTTP status on "classic" errors...
	if resp.StatusCode != http.StatusOK {
		var apiErr deezerAPIErrorResponse
		// ...but it can also return a 200 status with an "error" object in
		// the JSON body. So we try to parse it here too, to get a more
		// precise error message than just the HTTP status code.
		if json.Unmarshal(body, &apiErr) == nil && apiErr.Error.Code != 0 {
			return fmt.Errorf("deezer api error: %s", apiErr.Error.Message)
		}
		return fmt.Errorf("deezer api returned status %d", resp.StatusCode)
	}

	if err := json.Unmarshal(body, target); err != nil {
		return fmt.Errorf("failed to decode deezer json: %w", err)
	}

	return nil
}

// mapTrack converts a track from Deezer's internal format into the
// protobuf DTO pb.SongDTO used by the rest of the application.
func (c *DeezerClient) mapTrack(track *deezerTrack) *pb.SongDTO {
	return &pb.SongDTO{
		Id:              -1, // The internal ID is not set here; it will be generated by the database.
		DeezerSongId:    int64(track.ID),
		Title:           track.Title,
		DurationSeconds: int64(30), // Deezer provides a 30-second preview, so we set the duration to 30 seconds.
		ArtistName:      track.Artist.Name,
		DeezerArtistId:  int64(track.Artist.ID),
		AlbumTitle:      track.Album.Title,
		DeezerAlbumId:   int64(track.Album.ID),
		CoverUrl:        firstNonEmpty(track.Album.CoverMedium, track.Album.CoverBig),
		PreviewUrl:      track.Preview, // Deezer provides a 30-second preview URL for each track.
	}
}

// mapTracks applies mapTrack to an entire list of tracks.
func (c *DeezerClient) mapTracks(tracks []deezerTrack) []*pb.SongDTO {
	result := make([]*pb.SongDTO, 0, len(tracks))
	for _, track := range tracks {
		result = append(result, c.mapTrack(&track))
	}
	return result
}

// firstNonEmpty returns the first non-empty (after trimming) string among
// the given arguments. Useful for picking between several image sizes
// (e.g. prefer cover_medium, fall back to cover_big).
// Returns "" if all values are empty.
func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}
