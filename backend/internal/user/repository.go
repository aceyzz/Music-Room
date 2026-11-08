package user

import (
	"context"
	"errors"
	"fmt"
	"time"

	sqlc "example.com/music-app/db/sqlc"
	"example.com/music-app/internal/authz"
	"example.com/music-app/internal/authz/outbox"
	"example.com/music-app/internal/media"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
)

// User est la représentation métier d'un compte : des types Go simples,
// sans rien qui vienne de pgx ou de sqlc.
type User struct {
	// ID est l'id interne : jamais renvoye au client, mais le service
	// d'inscription en a besoin pour emettre le code de verification.
	ID          int64
	PublicID    string
	DisplayName string
	Email       string
}

// DB : de quoi lire, écrire, et surtout ouvrir une transaction. Défini une seule
// fois dans le package outbox, parce que les quatre repositories qui appliquent
// le pattern en ont besoin à l'identique. *pgxpool.Pool le satisfait.
type DB = outbox.DB

// Repository écrit et lit la table users, son profil, et les relations sociales
// qui portent des permissions.
//
// Deux handles sur la même base, pour deux besoins distincts : q pour les
// requêtes isolées (comme les autres repositories du projet), db pour celles
// qui doivent ouvrir une transaction — toute mutation qui doit des tuples en a
// besoin, parce que la ligne et son intention de synchronisation doivent être
// atomiques (voir outbox).
type Repository struct {
	db     DB
	q      *sqlc.Queries
	outbox *outbox.Outbox
}

// Credentials est ce que le login a besoin de savoir. Un type distinct de User
// parce qu'il porte le hash du mot de passe : rien de tout ça ne doit finir
// dans une réponse API.
type Credentials struct {
	ID            int64
	PublicID      string
	DisplayName   string
	Email         string
	PasswordHash  string
	HasPassword   bool
	Status        string
	EmailVerified bool
}

var (
	ErrEmailTaken       = errors.New("email already taken")
	ErrDisplayNameTaken = errors.New("display name already taken")
	ErrNotFound         = errors.New("user not found")
)

// OAuthIdentity : ce qu'un provider dit d'un utilisateur.
type OAuthIdentity struct {
	Provider       string
	ProviderUserID string
	Email          string
	DisplayName    string
	EmailVerified  bool
}

var (
	ErrIdentityAlreadyLinked = errors.New("identity already linked to another account")
	ErrProviderAlreadyLinked = errors.New("account already linked to this provider")
	ErrProviderNotLinked     = errors.New("provider not linked to this account")
	ErrLastLoginMethod       = errors.New("cannot remove the last login method")
)

func NewRepository(db DB, ob *outbox.Outbox) *Repository {
	return &Repository{db: db, q: sqlc.New(db), outbox: ob}
}

// Create crée un compte : la ligne users, son user_profiles, et l'intention
// d'écrire les tuples OpenFGA correspondants — le tout dans une seule
// transaction. passwordHash est déjà hashé par l'appelant : ce fichier ne fait
// pas de crypto.
//
// La transaction est ici et non dans le service parce que c'est elle qui porte
// la garantie : les tuples doivent être atomiques avec la ligne qu'ils
// décrivent, donc celui qui ouvre la transaction est aussi celui qui met la
// demande de synchronisation dedans (voir le package outbox).
//
// Deux choses qui n'existaient pas avant, et qui ne sont pas des détails :
//
//   - La ligne user_profiles. Sans elle, les valeurs par défaut de visibilité
//     choisies dans le schéma ne s'appliquaient à personne — la ligne sur
//     laquelle elles portent n'était jamais créée, et GetUserProfile ne
//     renvoyait rien pour n'importe quel compte.
//   - Les tuples du nouvel utilisateur. account_owner et anyone sont des
//     relations directes dans le modèle : sans elles, l'utilisateur ne peut pas
//     modifier son propre profil et reste invisible pour tous les autres.
func (r *Repository) Create(ctx context.Context, displayName, email, passwordHash string) (User, error) {
	return outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) (User, []authz.Change, error) {
			queries := sqlc.New(tx)

			row, err := queries.CreateUser(ctx, sqlc.CreateUserParams{
				DisplayName:  displayName,
				Email:        email,
				PasswordHash: pgtype.Text{String: passwordHash, Valid: true},
			})
			if err != nil {
				return User{}, nil, translateError(err)
			}

			if _, err := queries.CreateUserProfile(ctx, row.ID); err != nil {
				return User{}, nil, fmt.Errorf("création du profil : %w", err)
			}

			publicID := row.PublicID.String()
			change := authz.NewUser(publicID)

			return User{
				ID:          row.ID,
				PublicID:    publicID,
				DisplayName: row.DisplayName,
				Email:       row.Email,
			}, []authz.Change{change}, nil
		})
}

// translateError examine l'erreur retournée par pgx et renvoie une erreur métier
// plus lisible. Si l'erreur n'est pas reconnue, elle est renvoyée telle quelle.
func translateError(err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		switch pgErr.ConstraintName {
		case "users_email_key":
			return ErrEmailTaken
		case "users_display_name_key":
			return ErrDisplayNameTaken
		}
	}
	return err
}

// FindCredentialsByEmail lit l'utilisateur pour une tentative de connexion.
func (r *Repository) FindCredentialsByEmail(ctx context.Context, email string) (Credentials, error) {
	row, err := r.q.GetUserByEmail(ctx, email)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Credentials{}, ErrNotFound
		}
		return Credentials{}, err
	}

	return Credentials{
		ID:            row.ID,
		PublicID:      row.PublicID.String(),
		DisplayName:   row.DisplayName,
		Email:         row.Email,
		PasswordHash:  row.PasswordHash.String,
		HasPassword:   row.PasswordHash.Valid,
		Status:        string(row.Status),
		EmailVerified: row.EmailVerifiedAt.Valid,
	}, nil
}

// FindByProviderIdentity : cette identite provider est-elle deja connue ?
func (r *Repository) FindByProviderIdentity(ctx context.Context, provider, providerUserID string) (Credentials, error) {
	row, err := r.q.GetUserByProviderIdentity(ctx, sqlc.GetUserByProviderIdentityParams{
		Provider:       sqlc.OauthProvider(provider),
		ProviderUserID: providerUserID,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Credentials{}, ErrNotFound
		}
		return Credentials{}, err
	}

	return Credentials{
		ID:            row.ID,
		PublicID:      row.PublicID.String(),
		DisplayName:   row.DisplayName,
		Email:         row.Email,
		Status:        string(row.Status),
		EmailVerified: row.EmailVerifiedAt.Valid,
	}, nil
}

// CreateFromOAuth cree un compte sans mot de passe.
// emailVerified vient du provider : Google et 42 verifient l'adresse, donc
// pas de mail de confirmation a envoyer.
//
// Meme transaction que Create, pour les memes raisons : la ligne
// user_profiles et les tuples du nouvel utilisateur (account_owner, anyone).
// Cette fonction n'ecrivait que la ligne users, si bien qu'un compte cree par
// OAuth n'avait aucun tuple : can_view_profile refusait GetUser (NOT_FOUND sur
// son propre profil), can_edit_profile refusait toute modification, et les
// autres ne pouvaient ni le voir ni l'inviter.
func (r *Repository) CreateFromOAuth(ctx context.Context, displayName, email string, emailVerified bool) (Credentials, error) {
	var verifiedAt pgtype.Timestamptz
	if emailVerified {
		verifiedAt = pgtype.Timestamptz{Time: time.Now(), Valid: true}
	}

	return outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) (Credentials, []authz.Change, error) {
			queries := sqlc.New(tx)

			row, err := queries.CreateOAuthUser(ctx, sqlc.CreateOAuthUserParams{
				DisplayName:     displayName,
				Email:           email,
				EmailVerifiedAt: verifiedAt,
			})
			if err != nil {
				return Credentials{}, nil, translateError(err)
			}

			if _, err := queries.CreateUserProfile(ctx, row.ID); err != nil {
				return Credentials{}, nil, fmt.Errorf("création du profil : %w", err)
			}

			publicID := row.PublicID.String()
			return Credentials{
				ID:            row.ID,
				PublicID:      publicID,
				DisplayName:   row.DisplayName,
				Email:         row.Email,
				Status:        string(row.Status),
				EmailVerified: row.EmailVerifiedAt.Valid,
			}, []authz.Change{authz.NewUser(publicID)}, nil
		})
}

// LinkOAuthIdentity rattache une identite provider a un compte.
// 23505 sur l'une des deux contraintes uniques = identite deja liee ailleurs.
func (r *Repository) LinkOAuthIdentity(ctx context.Context, userID int64, provider, providerUserID, providerEmail string) error {
	_, err := r.q.LinkOAuthAccount(ctx, sqlc.LinkOAuthAccountParams{
		UserID:         userID,
		Provider:       sqlc.OauthProvider(provider),
		ProviderUserID: providerUserID,
		ProviderEmail:  pgtype.Text{String: providerEmail, Valid: providerEmail != ""},
	})

	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		if pgErr.ConstraintName == "user_oauth_accounts_user_provider_key" {
			return ErrProviderAlreadyLinked
		}
		return ErrIdentityAlreadyLinked
	}
	return err
}

// LinkedIdentity : une identite provider deja rattachee, telle que l'ecran
// "Comptes lies" la montre. Pas de provider_user_id : le client n'en a pas
// l'usage, et c'est l'identifiant qui sert a se connecter.
type LinkedIdentity struct {
	Provider string
	Email    string
	LinkedAt time.Time
}

// ListOAuthIdentities : les identites liees au compte, plus le fait qu'il ait
// un mot de passe -- les deux ensemble disent si Unlink accepterait de retirer
// la derniere. Deux lectures hors transaction : un ecart entre elles ne fait
// qu'afficher un bouton qu'Unlink refusera, puisqu'il repose la question sous
// verrou.
func (r *Repository) ListOAuthIdentities(ctx context.Context, userID int64) ([]LinkedIdentity, bool, error) {
	hasPassword, err := r.q.UserHasPassword(ctx, userID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, false, ErrNotFound
		}
		return nil, false, err
	}

	rows, err := r.q.ListOAuthAccounts(ctx, userID)
	if err != nil {
		return nil, false, err
	}

	identities := make([]LinkedIdentity, 0, len(rows))
	for _, row := range rows {
		identities = append(identities, LinkedIdentity{
			Provider: string(row.Provider),
			Email:    row.ProviderEmail.String,
			LinkedAt: row.LinkedAt.Time,
		})
	}
	return identities, hasPassword, nil
}

// --- profile -----------------------------------------------------------------

// UpdateProfile applies a partial profile update. The per-field visibility is
// applied when the profile is read (GetUser), from this same row.
func (r *Repository) UpdateProfile(ctx context.Context, params sqlc.UpsertUserProfileParams) (sqlc.UserProfile, error) {
	return r.q.UpsertUserProfile(ctx, params)
}

// --- avatar ------------------------------------------------------------------

// AvatarUpload is everything SetAvatar needs. The resize and the two file writes
// have already happened by then -- they talk to another process and to the disk,
// and neither belongs inside a transaction.
type AvatarUpload struct {
	UserID      int64
	ContentType string

	OriginalKey  string
	OriginalSize int
	ThumbKey     string
	ThumbSize    int
	ThumbPixels  int

	// PreviousAvatarImageID is the avatar being replaced. Invalid when there was
	// none.
	PreviousAvatarImageID pgtype.Int8
}

// SetAvatar writes the two image rows, points the profile at the thumbnail, and
// removes whatever avatar was there before.
//
// Returns the replaced files' storage keys for the caller to delete AFTER this
// returns: the transaction has committed by then, so no rollback can leave the
// profile pointing at a file that is already gone.
//
// An avatar is world-viewable by design -- there is no avatar_visibility column
// in the data model and none is wanted. So the original carries `public`, and the
// thumbnail inherits it through `original` rather than carrying its own.
func (r *Repository) SetAvatar(ctx context.Context, upload AvatarUpload) ([]string, error) {
	return outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) ([]string, []authz.Change, error) {
			queries := sqlc.New(tx)

			userPublicID, err := queries.GetUserPublicID(ctx, upload.UserID)
			if err != nil {
				return nil, nil, err
			}
			owner := userPublicID.String()

			original, err := queries.CreateImage(ctx, sqlc.CreateImageParams{
				OwnerUserID: upload.UserID,
				StorageKey:  upload.OriginalKey,
				ContentType: upload.ContentType,
				ByteSize:    pgtype.Int4{Int32: int32(upload.OriginalSize), Valid: true},
				Variant:     "original",
			})
			if err != nil {
				return nil, nil, err
			}
			thumb, err := queries.CreateImage(ctx, sqlc.CreateImageParams{
				OwnerUserID:   upload.UserID,
				StorageKey:    upload.ThumbKey,
				ContentType:   "image/png",
				Width:         pgtype.Int4{Int32: int32(upload.ThumbPixels), Valid: true},
				Height:        pgtype.Int4{Int32: int32(upload.ThumbPixels), Valid: true},
				ByteSize:      pgtype.Int4{Int32: int32(upload.ThumbSize), Valid: true},
				Variant:       "thumb",
				SourceImageID: pgtype.Int8{Int64: original.ID, Valid: true},
			})
			if err != nil {
				return nil, nil, err
			}

			if _, err := queries.UpsertUserProfile(ctx, sqlc.UpsertUserProfileParams{
				UserID:        upload.UserID,
				AvatarImageID: pgtype.Int8{Int64: thumb.ID, Valid: true},
			}); err != nil {
				return nil, nil, err
			}

			changes := media.NewImagePair(
				original, thumb, owner, authz.AvatarAttachment(), authz.OriginAvatarUpload,
			)
			staleFiles, staleChanges, err := media.DeleteImagePair(
				ctx, queries, upload.PreviousAvatarImageID, owner,
				authz.AvatarAttachment(), authz.OriginAvatarUpload,
			)
			if err != nil {
				return nil, nil, err
			}
			return staleFiles, append(changes, staleChanges...), nil
		})
}

// ClearAvatar removes the profile's avatar, if it had one.
func (r *Repository) ClearAvatar(ctx context.Context, userID int64, avatarImageID pgtype.Int8) ([]string, error) {
	return outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) ([]string, []authz.Change, error) {
			if !avatarImageID.Valid {
				return nil, nil, nil
			}
			queries := sqlc.New(tx)

			userPublicID, err := queries.GetUserPublicID(ctx, userID)
			if err != nil {
				return nil, nil, err
			}
			if err := queries.ClearUserAvatar(ctx, userID); err != nil {
				return nil, nil, err
			}

			return media.DeleteImagePair(
				ctx, queries, avatarImageID, userPublicID.String(),
				authz.AvatarAttachment(), authz.OriginAvatarDelete,
			)
		})
}

// --- social ------------------------------------------------------------------

// AcceptFriendRequest answers the request and creates the friendship row, in
// one transaction.
func (r *Repository) AcceptFriendRequest(ctx context.Context, requestID, addresseeID int64) (sqlc.AcceptFriendRequestRow, error) {
	var accepted sqlc.AcceptFriendRequestRow
	err := pgx.BeginFunc(ctx, r.db, func(tx pgx.Tx) error {
		queries := sqlc.New(tx)

		var err error
		accepted, err = queries.AcceptFriendRequest(ctx, sqlc.AcceptFriendRequestParams{
			ID: requestID, AddresseeID: addresseeID,
		})
		if err != nil {
			return err
		}
		_, err = queries.CreateFriendship(ctx, sqlc.CreateFriendshipParams{
			UserID:    accepted.RequesterID,
			FriendID:  accepted.AddresseeID,
			RequestID: pgtype.Int8{Int64: accepted.ID, Valid: true},
		})
		return err
	})
	return accepted, err
}

// Block breaks the friendship, cancels pending requests, blocks the user, and
// revokes every device grant between the two.
//
// That last step is the one worth reading twice. Control delegation is
// friends-only as a WRITE-time precondition and nothing re-checks the
// friendship when a licence is used, so the grant does not lapse when the
// friendship does -- it has to be taken back explicitly. Without it, blocking
// someone leaves them driving your speaker.
func (r *Repository) Block(ctx context.Context, blockerID, blockedID int64) error {
	_, err := outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) (struct{}, []authz.Change, error) {
			queries := sqlc.New(tx)

			blocker, err := queries.GetUserPublicID(ctx, blockerID)
			if err != nil {
				return struct{}{}, nil, err
			}
			blocked, err := queries.GetUserPublicID(ctx, blockedID)
			if err != nil {
				return struct{}{}, nil, err
			}

			if err := queries.DeleteFriendship(ctx, sqlc.DeleteFriendshipParams{
				UserID: blockerID, OtherUserID: blockedID,
			}); err != nil {
				return struct{}{}, nil, err
			}
			if err := queries.CancelPendingFriendRequestsBetween(ctx, sqlc.CancelPendingFriendRequestsBetweenParams{
				UserID: blockerID, OtherUserID: blockedID,
			}); err != nil {
				return struct{}{}, nil, err
			}
			if err := queries.BlockUser(ctx, sqlc.BlockUserParams{
				BlockerID: blockerID, BlockedID: blockedID,
			}); err != nil {
				return struct{}{}, nil, err
			}

			if err := queries.RevokeDeviceGrantsBetween(ctx, sqlc.RevokeDeviceGrantsBetweenParams{
				UserID: blockerID, OtherUserID: blockedID,
			}); err != nil {
				return struct{}{}, nil, err
			}
			return struct{}{}, []authz.Change{authz.Block(blocker.String(), blocked.String())}, nil
		})
	return err
}

// Unblock lifts the block.
//
// It does not restore the friendship: blocking deleted that row, so there is
// nothing to transcribe back. The two have to befriend again, which is the
// product behaviour and not an omission -- and it is why no grant is restored
// either.
func (r *Repository) Unblock(ctx context.Context, blockerID, blockedID int64) error {
	_, err := outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) (struct{}, []authz.Change, error) {
			queries := sqlc.New(tx)

			blocker, err := queries.GetUserPublicID(ctx, blockerID)
			if err != nil {
				return struct{}{}, nil, err
			}
			blocked, err := queries.GetUserPublicID(ctx, blockedID)
			if err != nil {
				return struct{}{}, nil, err
			}

			if err := queries.UnblockUser(ctx, sqlc.UnblockUserParams{
				BlockerID: blockerID, BlockedID: blockedID,
			}); err != nil {
				return struct{}{}, nil, err
			}

			// The graph's block is symmetric and one tuple pair serves both rows:
			// if the other user still blocks back, the pair must stay. Deleting
			// it would let one unblock lift a mutual block. IsBlocked checks both
			// directions, and ours is gone, so true means theirs remains.
			stillBlocked, err := queries.IsBlocked(ctx, sqlc.IsBlockedParams{
				UserID: blockerID, OtherUserID: blockedID,
			})
			if err != nil {
				return struct{}{}, nil, err
			}
			if stillBlocked {
				return struct{}{}, nil, nil
			}

			change := authz.Unblock(blocker.String(), blocked.String())
			return struct{}{}, []authz.Change{change}, nil
		})
	return err
}

// Unfriend ends a friendship and revokes every device grant between the two,
// in one transaction.
//
// The grants for the same reason as Block: delegation is friends-only at grant
// time, and nothing re-checks the friendship afterwards, so a grant to an
// ex-friend would stay live (docs/permissions.md §11). Idempotent: with no
// friendship there is nothing to delete.
func (r *Repository) Unfriend(ctx context.Context, userID, friendID int64) error {
	return pgx.BeginFunc(ctx, r.db, func(tx pgx.Tx) error {
		queries := sqlc.New(tx)

		if err := queries.DeleteFriendship(ctx, sqlc.DeleteFriendshipParams{
			UserID: userID, OtherUserID: friendID,
		}); err != nil {
			return err
		}
		return queries.RevokeDeviceGrantsBetween(ctx, sqlc.RevokeDeviceGrantsBetweenParams{
			UserID: userID, OtherUserID: friendID,
		})
	})
}

func (r *Repository) ResetPassword(ctx context.Context, userID int64, passwordHash string) error {
	_, err := outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) (struct{}, []authz.Change, error) {
			queries := sqlc.New(tx)

			rows, err := queries.UpdateUserPassword(ctx, sqlc.UpdateUserPasswordParams{
				ID:           userID,
				PasswordHash: pgtype.Text{String: passwordHash, Valid: true},
			})
			if err != nil {
				return struct{}{}, nil, err
			}
			if rows == 0 {
				return struct{}{}, nil, ErrNotFound
			}

			if _, err := queries.RevokeAllUserSessions(ctx, sqlc.RevokeAllUserSessionsParams{
				RevokedReason: sqlc.NullSessionRevokedReason{
					SessionRevokedReason: sqlc.SessionRevokedReasonPasswordChange,
					Valid:                true,
				},
				UserID:          userID,
				ExceptSessionID: 0,
			}); err != nil {
				return struct{}{}, nil, err
			}

			return struct{}{}, nil, nil
		})
	return err
}

func (r *Repository) UnlinkOAuthIdentity(ctx context.Context, userID int64, provider string) error {
	_, err := outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) (struct{}, []authz.Change, error) {
			queries := sqlc.New(tx)

			hasPassword, err := queries.LockUserForCredentialChange(ctx, userID)
			if err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return struct{}{}, nil, ErrNotFound
				}
				return struct{}{}, nil, err
			}

			linked, err := queries.CountOAuthAccounts(ctx, userID)
			if err != nil {
				return struct{}{}, nil, err
			}

			rows, err := queries.DeleteOAuthAccount(ctx, sqlc.DeleteOAuthAccountParams{
				UserID:   userID,
				Provider: sqlc.OauthProvider(provider),
			})
			if err != nil {
				return struct{}{}, nil, err
			}
			if rows == 0 {
				return struct{}{}, nil, ErrProviderNotLinked
			}

			if !hasPassword && linked <= 1 {
				return struct{}{}, nil, ErrLastLoginMethod
			}

			return struct{}{}, nil, nil
		})
	return err
}
