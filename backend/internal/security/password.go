package security

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"

	"golang.org/x/crypto/argon2"
)

var (
	ErrPasswordMismatch = errors.New("password mismatch")
	ErrInvalidHash      = errors.New("invalid hash format")
)

// Paramètres Argon2id. Ils sont écrits DANS le hash produit, donc les changer
// ici n'invalide pas les mots de passe déjà enregistrés.
const (
	argonTime    = 1
	argonMemory  = 64 * 1024 // 64 Mo
	argonThreads = 4
	argonKeyLen  = 32
	saltLen      = 16
)

type Argon2Hasher struct{}

func NewArgon2Hasher() Argon2Hasher {
	return Argon2Hasher{}
}

// Hash produit une chaîne au format standard PHC :
// $argon2id$v=19$m=65536,t=1,p=4$<sel>$<empreinte>
// Tout ce qu'il faut pour re-vérifier plus tard est dedans.
func (Argon2Hasher) Hash(password string) (string, error) {
	salt := make([]byte, saltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}

	key := argon2.IDKey([]byte(password), salt, argonTime, argonMemory, argonThreads, argonKeyLen)

	return fmt.Sprintf(
		"$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, argonMemory, argonTime, argonThreads,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(key),
	), nil
}

// Verify relit les paramètres depuis le hash stocké, recalcule l'empreinte,
// et compare en temps constant pour ne pas laisser fuir d'information par la
// durée de la réponse.
func (Argon2Hasher) Verify(password, encodedHash string) error {
	parts := strings.Split(encodedHash, "$")
	if len(parts) != 6 || parts[1] != "argon2id" {
		return ErrInvalidHash
	}

	var version int
	if _, err := fmt.Sscanf(parts[2], "v=%d", &version); err != nil || version != argon2.Version {
		return ErrInvalidHash
	}

	var memory, time uint32
	var threads uint8
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &memory, &time, &threads); err != nil {
		return ErrInvalidHash
	}

	salt, err := base64.RawStdEncoding.Strict().DecodeString(parts[4])
	if err != nil {
		return ErrInvalidHash
	}

	want, err := base64.RawStdEncoding.Strict().DecodeString(parts[5])
	if err != nil {
		return ErrInvalidHash
	}

	got := argon2.IDKey([]byte(password), salt, time, memory, threads, uint32(len(want)))

	if subtle.ConstantTimeCompare(got, want) != 1 {
		return ErrPasswordMismatch
	}
	return nil
}
