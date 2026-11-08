package event

import (
	"testing"
	"time"

	db "example.com/music-app/db/sqlc"
	"github.com/jackc/pgx/v5/pgtype"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestEventDTOTimes(t *testing.T) {
	start := time.Date(2026, 10, 15, 20, 0, 0, 0, time.UTC)
	dto := eventDTO(db.Event{
		StartsAt: pgtype.Timestamptz{Time: start, Valid: true},
		EndsAt:   pgtype.Timestamptz{Time: start.Add(3 * time.Hour), Valid: true},
	})
	if dto.GetStartsAt() != start.Unix() || dto.GetEndsAt() != start.Add(3*time.Hour).Unix() {
		t.Errorf("got starts_at=%d ends_at=%d", dto.GetStartsAt(), dto.GetEndsAt())
	}

	// NULL on the row (an event created without times) is 0 on the wire.
	dto = eventDTO(db.Event{})
	if dto.GetStartsAt() != 0 || dto.GetEndsAt() != 0 {
		t.Errorf("unset times: got starts_at=%d ends_at=%d, want 0", dto.GetStartsAt(), dto.GetEndsAt())
	}
}

func TestEventWindow(t *testing.T) {
	now := time.Date(2026, 10, 15, 20, 0, 0, 0, time.UTC)
	hour := int64(3600)
	cases := []struct {
		name             string
		startsAt, endsAt int64
		wantErr          bool
	}{
		{"both unset", 0, 0, true},
		{"only the start", now.Unix() + hour, 0, true},
		{"only the end", 0, now.Unix() + hour, true},
		{"ends before it starts", now.Unix() + 2*hour, now.Unix() + hour, true},
		{"ends when it starts", now.Unix() + hour, now.Unix() + hour, true},
		{"already over", now.Unix() - 3*hour, now.Unix() - hour, true},
		{"ends right now", now.Unix() - hour, now.Unix(), true},
		{"starts in the past, ends later: starting now", now.Unix() - hour, now.Unix() + hour, false},
		{"upcoming", now.Unix() + hour, now.Unix() + 4*hour, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			starts, ends, err := eventWindow(c.startsAt, c.endsAt, now)
			if c.wantErr {
				if status.Code(err) != codes.InvalidArgument {
					t.Fatalf("got err %v, want InvalidArgument", err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if starts.Time.Unix() != c.startsAt || ends.Time.Unix() != c.endsAt || !starts.Valid || !ends.Valid {
				t.Errorf("got %+v %+v, want %d %d", starts, ends, c.startsAt, c.endsAt)
			}
		})
	}
}
