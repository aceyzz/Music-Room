// package media : client du image-service Rust (resize) et stockage local
// des fichiers qu'il produit. Pas d'objet S3/MinIO dans ce projet : les
// fichiers vivent sous un répertoire monté en volume, servis tels quels par
// un handler HTTP statique (cmd/main.go), et `storage_key` (colonne
// `images.storage_key`, docs/data-model.md §6) est le chemin relatif à ce
// répertoire.
package media

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
)

// MaxUploadBytes : taille maximale d'une image envoyée par un client (avatar,
// cover de playlist). Trois couches en dépendent et doivent rester d'accord,
// sinon la plus basse gagne en silence :
//   - les validateurs des services (user.validAvatarUpload,
//     playlist.validCoverUpload), qui renvoient un message clair ;
//   - grpc.MaxRecvMsgSize dans cmd/main.go, au-dessus de cette valeur
//     (gRPC-Go refuse tout message de plus de 4 Mio par défaut) ;
//   - DefaultBodyLimit dans image-service/src/main.rs, qui reçoit l'image en
//     base64 dans du JSON, donc ~4/3 de cette valeur.
const MaxUploadBytes = 5 << 20 // 5 Mio

// ErrInvalidImage : image-service a refusé les octets envoyés (pas une
// image décodable, ou dimensions nulles). Distinct d'une panne du service
// lui-même, pour que l'appelant renvoie InvalidArgument plutôt qu'Internal.
var ErrInvalidImage = errors.New("invalid image data")

// Client parle au image-service (image-service/src/main.rs) : un seul
// endpoint, /resize, qui ne persiste jamais rien lui-même.
type Client struct {
	baseURL string
	http    *http.Client
}

func NewClient(baseURL string) *Client {
	return &Client{baseURL: baseURL, http: &http.Client{}}
}

type resizeRequest struct {
	ImageBase64 string `json:"image_base64"`
	Width       int    `json:"width"`
	Height      int    `json:"height"`
}

type resizeResponse struct {
	ImageBase64 string `json:"image_base64"`
}

// Resize envoie `data` à image-service et renvoie l'image redimensionnée.
// Toujours du PNG en sortie : image-service encode systématiquement en PNG
// (encode_png dans image-service/src/main.rs), quel que soit le format
// d'entrée.
func (c *Client) Resize(ctx context.Context, data []byte, width, height int) ([]byte, error) {
	payload, err := json.Marshal(resizeRequest{
		ImageBase64: base64.StdEncoding.EncodeToString(data),
		Width:       width,
		Height:      height,
	})
	if err != nil {
		return nil, fmt.Errorf("could not encode resize request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/resize", bytes.NewReader(payload))
	if err != nil {
		return nil, fmt.Errorf("could not build resize request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("image-service request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("could not read image-service response: %w", err)
	}

	if resp.StatusCode == http.StatusBadRequest {
		return nil, fmt.Errorf("%w: %s", ErrInvalidImage, body)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("image-service returned status %d", resp.StatusCode)
	}

	var decoded resizeResponse
	if err := json.Unmarshal(body, &decoded); err != nil {
		return nil, fmt.Errorf("could not decode image-service response: %w", err)
	}
	out, err := base64.StdEncoding.DecodeString(decoded.ImageBase64)
	if err != nil {
		return nil, fmt.Errorf("could not decode resized image: %w", err)
	}
	return out, nil
}
