package user

import (
	"testing"
	"time"

	db "example.com/music-app/db/sqlc"
	pb "example.com/music-app/gen/go/music_room/v1"
	"github.com/jackc/pgx/v5/pgtype"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func TestProfileParamsAbsentFieldsAreLeftAlone(t *testing.T) {
	p, err := profileParams(&pb.UpdateUserProfileRequest{UserId: 7})
	if err != nil {
		t.Fatalf("profileParams: %v", err)
	}
	want := db.UpsertUserProfileParams{UserID: 7}
	if p != want {
		t.Fatalf("got %+v, want only the user id", p)
	}
}

func TestProfileParamsEmptyFieldsAreCleared(t *testing.T) {
	empty := proto.String("")
	p, err := profileParams(&pb.UpdateUserProfileRequest{
		UserId: 7, FirstName: empty, LastName: empty, Bio: empty, BirthDate: empty,
		City: empty, CountryCode: empty, PhoneNumber: empty,
	})
	if err != nil {
		t.Fatalf("profileParams: %v", err)
	}
	set := []bool{p.SetFirstName, p.SetLastName, p.SetBio, p.SetBirthDate, p.SetCity, p.SetCountryCode, p.SetPhoneNumber}
	for i, s := range set {
		if !s {
			t.Errorf("field %d: Set flag is false, want true (sent empty = clear)", i)
		}
	}
	texts := []pgtype.Text{p.FirstName, p.LastName, p.Bio, p.City, p.CountryCode, p.PhoneNumber}
	for i, v := range texts {
		if v.Valid {
			t.Errorf("text field %d: got %q, want NULL", i, v.String)
		}
	}
	if p.BirthDate.Valid {
		t.Errorf("birth_date: got %v, want NULL", p.BirthDate.Time)
	}
}

func TestProfileParamsValuesAndScopes(t *testing.T) {
	p, err := profileParams(&pb.UpdateUserProfileRequest{
		UserId:              7,
		Bio:                 proto.String("hello"),
		BirthDate:           proto.String("1990-03-07"),
		BioVisibility:       "private",
		LocationVisibility:  "", // unchanged
		PhoneVisibility:     "friends",
		FirstNameVisibility: "public",
	})
	if err != nil {
		t.Fatalf("profileParams: %v", err)
	}
	if !p.SetBio || p.Bio != (pgtype.Text{String: "hello", Valid: true}) {
		t.Errorf("bio: got set=%v %+v", p.SetBio, p.Bio)
	}
	if !p.SetBirthDate || !p.BirthDate.Time.Equal(time.Date(1990, 3, 7, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("birth_date: got set=%v %+v", p.SetBirthDate, p.BirthDate)
	}
	if p.SetFirstName || p.SetCity {
		t.Errorf("fields not sent must not be set: first_name=%v city=%v", p.SetFirstName, p.SetCity)
	}
	if p.BioVisibility != (db.NullVisibilityScope{VisibilityScope: "private", Valid: true}) {
		t.Errorf("bio_visibility: got %+v", p.BioVisibility)
	}
	if p.LocationVisibility.Valid {
		t.Errorf("location_visibility: got %+v, want NULL (unchanged)", p.LocationVisibility)
	}
	if p.PhoneVisibility.VisibilityScope != "friends" || p.FirstNameVisibility.VisibilityScope != "public" {
		t.Errorf("scopes: phone=%+v first_name=%+v", p.PhoneVisibility, p.FirstNameVisibility)
	}
}

func TestProfileParamsRejectsBadInput(t *testing.T) {
	for name, req := range map[string]*pb.UpdateUserProfileRequest{
		"birth date": {UserId: 7, BirthDate: proto.String("07/03/1990")},
		"visibility": {UserId: 7, BioVisibility: "everyone"},
	} {
		if _, err := profileParams(req); status.Code(err) != codes.InvalidArgument {
			t.Errorf("%s: got %v, want InvalidArgument", name, err)
		}
	}
}

func TestLikePatternEscapesWildcards(t *testing.T) {
	cases := map[string]string{
		"anna":   "anna",
		"100%":   `100\%`,
		"a_b":    `a\_b`,
		`back\`:  `back\\`,
		`%_\`:    `\%\_\\`,
		"Zoë 42": "Zoë 42",
	}
	for in, want := range cases {
		if got := likePattern(in); got != want {
			t.Errorf("likePattern(%q) = %q, want %q", in, got, want)
		}
	}
}

// A blank query answers before touching the database: the app's search field
// is empty most of the time, and that is not an error.
func TestSearchUsersBlankQueryReturnsNobody(t *testing.T) {
	s := &Service{}
	for _, query := range []string{"", "   "} {
		resp, err := s.SearchUsers(t.Context(), &pb.SearchUsersRequest{ViewerId: 1, Query: query})
		if err != nil {
			t.Fatalf("query %q: %v", query, err)
		}
		if len(resp.GetUsers()) != 0 {
			t.Errorf("query %q: got %d users, want none", query, len(resp.GetUsers()))
		}
	}
	if _, err := s.SearchUsers(t.Context(), &pb.SearchUsersRequest{Query: "anna"}); status.Code(err) != codes.InvalidArgument {
		t.Errorf("no viewer: got %v, want InvalidArgument", err)
	}
}
