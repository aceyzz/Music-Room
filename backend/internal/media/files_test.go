package media

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestFileHandlerServesFilesNotDirectories(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "avatars"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "avatars", "a.png"), []byte("png"), 0o644); err != nil {
		t.Fatal(err)
	}

	handler := FileHandler(dir)

	for path, want := range map[string]int{
		"/avatars/a.png": http.StatusOK,
		"/":              http.StatusNotFound,
		"/avatars/":      http.StatusNotFound,
		"/avatars":       http.StatusNotFound,
		"/missing.png":   http.StatusNotFound,
	} {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != want {
			t.Errorf("%s: got %d, want %d", path, rec.Code, want)
		}
	}
}
