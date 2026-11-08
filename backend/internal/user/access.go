package user

import (
	db "example.com/music-app/db/sqlc"
	"example.com/music-app/internal/media"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// relation entre le viewer et le profil consulté : détermine quels champs
// visibility_scope laissent passer quoi (V.1 profil).
//
// En Go et pas dans OpenFGA : ce n'est pas un contrôle d'accès mais une
// rédaction. Elle ne décide pas si la réponse part (user#can_view_profile s'en
// charge, blocage compris), elle décide ce qu'elle contient, et tout ce qu'il
// faut pour ça est sur la ligne lue et dans friendships.
type relation int

const (
	relationSelf relation = iota
	relationFriend
	relationStranger
)

func resolveRelation(viewerID, targetID int64, areFriends bool) relation {
	if viewerID != 0 && viewerID == targetID {
		return relationSelf
	}
	if areFriends {
		return relationFriend
	}
	return relationStranger
}

// visibleTo dit si `scope` laisse `rel` voir le champ qu'il garde.
// Le propriétaire voit toujours son propre profil, quelle que soit la
// visibilité configurée.
func visibleTo(scope db.VisibilityScope, rel relation) bool {
	if rel == relationSelf {
		return true
	}
	switch scope {
	case db.VisibilityScopePublic:
		return true
	case db.VisibilityScopeFriends:
		return rel == relationFriend
	default: // private
		return false
	}
}

// defaultProfile : valeurs par défaut du schéma (db/schema/00008_profile.sql)
// quand un utilisateur n'a encore jamais écrit sa ligne user_profiles.
func defaultProfile(userID int64) db.UserProfile {
	return db.UserProfile{
		UserID:                userID,
		FirstNameVisibility:   db.VisibilityScopeFriends,
		LastNameVisibility:    db.VisibilityScopeFriends,
		BioVisibility:         db.VisibilityScopePublic,
		BirthDateVisibility:   db.VisibilityScopePrivate,
		LocationVisibility:    db.VisibilityScopeFriends,
		PhoneVisibility:       db.VisibilityScopePrivate,
		PreferencesVisibility: db.VisibilityScopePublic,
	}
}

// validVisibilityScope valide une chaîne envoyée par le client ; vide veut
// dire "inchangé" (voir UpsertUserProfile).
func validVisibilityScope(value string) (string, error) {
	if value == "" {
		return "", nil
	}
	switch value {
	case "public", "friends", "private":
		return value, nil
	default:
		return "", status.Error(codes.InvalidArgument, "visibility must be public, friends or private")
	}
}

// avatarExtensions : formats acceptés en upload -> extension de fichier pour
// l'original stocké. Le thumbnail, lui, est toujours en .png : image-service
// encode systématiquement en PNG (voir internal/media/client.go).
var avatarExtensions = map[string]string{
	"image/png":  "png",
	"image/jpeg": "jpg",
	"image/webp": "webp",
}

const maxAvatarBytes = media.MaxUploadBytes

func validAvatarUpload(contentType string, data []byte) (ext string, err error) {
	ext, ok := avatarExtensions[contentType]
	if !ok {
		return "", status.Error(codes.InvalidArgument, "content_type must be image/png, image/jpeg or image/webp")
	}
	if len(data) == 0 {
		return "", status.Error(codes.InvalidArgument, "image_data is required")
	}
	if len(data) > maxAvatarBytes {
		return "", status.Error(codes.InvalidArgument, "image must be smaller than 5MB")
	}
	return ext, nil
}
