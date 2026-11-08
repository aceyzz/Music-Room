package playlist

import (
	"example.com/music-app/internal/media"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Ce fichier ne contient plus que de la validation d'entrée.
//
// canViewPlaylist et canEditPlaylist vivaient ici. Elles répondaient, en Go et
// à partir de playlists.visibility / playlist_members.role, aux questions que
// le graphe répond maintenant : playlist#can_view et playlist#can_edit_songs,
// posées par l'intercepteur avant que le handler ne démarre
// (internal/interceptor/policy.go).
//
// Elles sont supprimées plutôt que gardées en second avis, et c'est un choix :
// deux systèmes de permissions en vol en même temps finissent par diverger,
// et le jour où ils divergent le plus permissif gagne. Les rôles admin et
// editor en sont la démonstration -- le code Go ne connaissait que
// "propriétaire ou membre", donc un admin ne pouvait pas changer la cover de
// sa propre playlist alors que le modèle le prévoit depuis le début.

func validEditLicense(value string) (string, error) {
	if value == "" {
		return "everyone", nil
	}
	if value != "everyone" && value != "invited_only" {
		return "", status.Error(codes.InvalidArgument, "edit_license must be everyone or invited_only")
	}
	return value, nil
}

// coverExtensions/maxCoverBytes/validCoverUpload mirror
// internal/user/access.go's avatar validation -- same formats, same limit.
// Kept separate rather than shared: two call sites don't justify a package
// just for this, and each service already owns its own small validators
// (validEditLicense right above, for instance). The limit itself is the one
// exception: it lives in media.MaxUploadBytes because the gRPC server and
// image-service must be configured above it too.
var coverExtensions = map[string]string{
	"image/png":  "png",
	"image/jpeg": "jpg",
	"image/webp": "webp",
}

const maxCoverBytes = media.MaxUploadBytes

func validCoverUpload(contentType string, data []byte) (ext string, err error) {
	ext, ok := coverExtensions[contentType]
	if !ok {
		return "", status.Error(codes.InvalidArgument, "content_type must be image/png, image/jpeg or image/webp")
	}
	if len(data) == 0 {
		return "", status.Error(codes.InvalidArgument, "image_data is required")
	}
	if len(data) > maxCoverBytes {
		return "", status.Error(codes.InvalidArgument, "image must be smaller than 5MB")
	}
	return ext, nil
}
