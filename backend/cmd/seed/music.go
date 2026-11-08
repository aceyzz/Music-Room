package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
)

// catalogue.json is 160 real Deezer tracks, ten per genre, resolved once
// through api.deezer.com/search when the seeder was written. Pinned rather than
// searched at seed time so the world (and the doc) is the same on every run,
// online or not; only the preview URLs, which Deezer signs and expires, are
// refreshed at seed time (refreshSongs in write.go).
//
//go:embed catalogue.json
var catalogueJSON []byte

type catalogueTrack struct {
	GenreID      int64  `json:"genre_id"`
	DeezerID     int64  `json:"deezer_id"`
	Title        string `json:"title"`
	Artist       string `json:"artist"`
	ArtistID     int64  `json:"artist_id"`
	Album        string `json:"album"`
	AlbumID      int64  `json:"album_id"`
	CoverURL     string `json:"cover_url"`
	Link         string `json:"link"`
	Explicit     bool   `json:"explicit"`
	Rank         int32  `json:"rank"`
	FullDuration int    `json:"full_duration"`
}

// Genres are Deezer's own ids and names (api.deezer.com/genre), the values
// user_music_preferences snapshots.
var Genres = []struct {
	ID   int64
	Name string
}{
	{132, "Pop"}, {116, "Rap/Hip Hop"}, {152, "Rock"}, {113, "Dance"},
	{165, "R&B"}, {85, "Alternative"}, {106, "Electro"}, {466, "Folk"},
	{144, "Reggae"}, {129, "Jazz"}, {98, "Classical"}, {173, "Films/Games"},
	{464, "Metal"}, {169, "Soul & Funk"}, {2, "African Music"}, {197, "Latin Music"},
}

// coverless are the tracks whose cover is dropped on purpose, so the app's
// placeholder (core/widgets/playlist_cover.dart) shows somewhere.
var coverless = map[int64]bool{
	29392051:   true, // Aphex Twin - Windowlicker
	96918062:   true, // Kamasi Washington - The Rhythm Changes
	2432265755: true, // Alpha Blondy - Jerusalem
}

func (w *World) buildSongs() {
	var tracks []catalogueTrack
	if err := json.Unmarshal(catalogueJSON, &tracks); err != nil {
		panic(fmt.Sprintf("catalogue.json: %v", err))
	}
	for i, t := range tracks {
		cover := t.CoverURL
		if coverless[t.DeezerID] {
			cover = ""
		}
		w.Songs = append(w.Songs, &Song{
			Idx: i, DeezerID: t.DeezerID, Title: t.Title, Artist: t.Artist, ArtistID: t.ArtistID,
			Album: t.Album, AlbumID: t.AlbumID, CoverURL: cover, Link: t.Link,
			Explicit: t.Explicit, Rank: t.Rank, GenreID: t.GenreID, FullDuration: t.FullDuration,
		})
	}
}

// songsOf returns the indices of the songs in the given genres.
func (w *World) songsOf(genres ...int64) []int {
	want := map[int64]bool{}
	for _, g := range genres {
		want[g] = true
	}
	var out []int
	for _, s := range w.Songs {
		if want[s.GenreID] {
			out = append(out, s.Idx)
		}
	}
	return out
}

// songByDeezer finds a catalogue song; a typo here is a bug, so it panics.
func (w *World) songByDeezer(id int64) int {
	for _, s := range w.Songs {
		if s.DeezerID == id {
			return s.Idx
		}
	}
	panic(fmt.Sprintf("no catalogue song %d", id))
}

func (w *World) allSongs() []int {
	out := make([]int, len(w.Songs))
	for i := range out {
		out[i] = i
	}
	return out
}

func genreName(id int64) string {
	for _, g := range Genres {
		if g.ID == id {
			return g.Name
		}
	}
	return ""
}
