package media

import (
	"net/http"
	"os"
)

func FileHandler(dir string) http.Handler {
	return http.FileServer(filesOnly{http.Dir(dir)})
}

type filesOnly struct {
	fs http.FileSystem
}

func (f filesOnly) Open(name string) (http.File, error) {
	file, err := f.fs.Open(name)
	if err != nil {
		return nil, err
	}
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, err
	}
	if info.IsDir() {
		file.Close()
		return nil, os.ErrNotExist
	}
	return file, nil
}
