package security

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"math"
	"math/big"
)

// sessionTokenBytes : 32 octets = 256 bits d'entropie. Non devinable.
const sessionTokenBytes = 32

// NewSessionToken renvoie le token en clair (à donner au client, une seule
// fois) et son empreinte (à stocker en base). Le clair n'est jamais persisté.
func NewSessionToken() (token string, hash []byte, err error) {
	raw := make([]byte, sessionTokenBytes)
	if _, err := rand.Read(raw); err != nil {
		return "", nil, err
	}

	token = base64.RawURLEncoding.EncodeToString(raw)
	return token, HashSessionToken(token), nil
}

// HashSessionToken recalcule l'empreinte d'un token présenté par un client.
// SHA-256 et pas Argon2id : le token n'est pas devinable, et ce calcul tourne
// à chaque requête authentifiée.
func HashSessionToken(token string) []byte {
	sum := sha256.Sum256([]byte(token))
	return sum[:]
}

// wrapper : donne une methode a NewSessionToken pour satisfaire une interface.
type SessionTokenGenerator struct{}

func NewSessionTokenGenerator() SessionTokenGenerator {
	return SessionTokenGenerator{}
}

func (SessionTokenGenerator) NewSessionToken() (string, []byte, error) {
	return NewSessionToken()
}

func (SessionTokenGenerator) HashSessionToken(token string) []byte {
	return HashSessionToken(token)
}

// codeDigits : 6 chiffres, soit 1 million de combinaisons. court parce qu'un
// humain le recopie. la faiblesse se compense par une expiration courte et
// une limite d'essais, pas par la longueur.
const codeDigits = 6

// NewEmailCode renvoie le code en clair (a envoyer) et son empreinte (a
// stocker). crypto/rand, jamais math/rand : un code previsible est un
// contournement de la verification.
func NewEmailCode() (code string, hash []byte, err error) {
	max := big.NewInt(int64(math.Pow10(codeDigits)))

	n, err := rand.Int(rand.Reader, max)
	if err != nil {
		return "", nil, err
	}

	code = fmt.Sprintf("%0*d", codeDigits, n.Int64())
	return code, HashSessionToken(code), nil
}

func (SessionTokenGenerator) NewEmailCode() (string, []byte, error) {
	return NewEmailCode()
}
