package media

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
)

// Store écrit et lit les fichiers sous un répertoire local (docker-compose :
// volume monté sur APP_IMAGE_STORAGE_DIR). `key` est toujours un chemin
// relatif à ce répertoire -- c'est la valeur stockée dans
// `images.storage_key`, et ce que le handler statique de cmd/main.go sert
// tel quel sous /media/.
type Store struct {
	dir string
}

func NewStore(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	return &Store{dir: dir}, nil
}

func (s *Store) Dir() string { return s.dir }

func (s *Store) Save(key string, data []byte) error {
	path := filepath.Join(s.dir, key)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

// Delete est best-effort : un remplacement d'avatar ne doit jamais échouer
// parce que le nettoyage de l'ancien fichier a raté (fichier déjà absent,
// permissions...), donc l'erreur est avalée plutôt que remontée.
func (s *Store) Delete(key string) {
	if key == "" {
		return
	}
	_ = os.Remove(filepath.Join(s.dir, key))
}

// NewObjectKey génère une clé aléatoire non devinable sous `prefix`, avec
// l'extension donnée -- même choix que security.NewSessionToken
// (crypto/rand, jamais math/rand, pour un identifiant qui ne se devine pas).
func NewObjectKey(prefix, ext string) (string, error) {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return filepath.Join(prefix, hex.EncodeToString(raw)+"."+ext), nil
}
