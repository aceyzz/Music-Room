package authz

import (
	"errors"
	"strings"
)

// ErrMalformedPublicID is returned for anything that is not one of the two
// textual UUID forms this API emits.
var ErrMalformedPublicID = errors.New("malformed public id")

// NormalizePublicID turns a public id as it arrives on the wire into the
// canonical dashed form tuples use.
//
// It accepts both forms because the API currently emits both, which is a real
// inconsistency and not a courtesy: AuthService returns pgtype.UUID.String()
// ("3ab93193-24a1-44ef-91a4-5d21c6ec9acb") while PlaylistDTO, MusicEventDTO and
// UserDTO all render public_id with hex.EncodeToString, producing the same UUID
// with no dashes. A client that echoes back the id it was given must work
// whichever RPC gave it to it, so normalizing on the way in is the cheap fix;
// making the DTOs agree is the real one (docs/todo.md).
//
// Rejecting the malformed rest matters more than it looks: the string goes on to
// name an FGA object, and an object that does not exist answers every Check with
// a flat denial rather than an error. A typo would look exactly like a
// permission problem.
func NormalizePublicID(raw string) (string, error) {
	compact := strings.ToLower(strings.ReplaceAll(strings.TrimSpace(raw), "-", ""))
	if len(compact) != 32 {
		return "", ErrMalformedPublicID
	}
	for i := 0; i < len(compact); i++ {
		c := compact[i]
		isHex := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
		if !isHex {
			return "", ErrMalformedPublicID
		}
	}

	var out strings.Builder
	out.Grow(36)
	for _, cut := range []int{8, 4, 4, 4, 12} {
		if out.Len() > 0 {
			out.WriteByte('-')
		}
		out.WriteString(compact[:cut])
		compact = compact[cut:]
	}
	return out.String(), nil
}
