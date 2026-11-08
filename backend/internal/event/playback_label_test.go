package event

import (
	"testing"

	db "example.com/music-app/db/sqlc"
)

func TestPlaybackLabel(t *testing.T) {
	cases := []struct {
		row  db.GetEventPlaybackSummariesRow
		want string
	}{
		{db.GetEventPlaybackSummariesRow{}, "idle"}, // no playback row: never started
		{db.GetEventPlaybackSummariesRow{HasSong: false, IsPaused: true}, "idle"},
		{db.GetEventPlaybackSummariesRow{HasSong: true, IsPaused: true}, "paused"},
		{db.GetEventPlaybackSummariesRow{HasSong: true}, "playing"},
	}
	for _, c := range cases {
		if got := playbackLabel(c.row); got != c.want {
			t.Errorf("%+v: got %q, want %q", c.row, got, c.want)
		}
	}
}
