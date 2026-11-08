-- Ajoute 'ownership_transfer' a playlist_op_type.
--
-- L'enum avait deja 'visibility_change'/'license_change'/'member_change'
-- depuis 00011_playlists (jamais branches cote Go jusqu'ici -- voir
-- internal/playlist/service.go), mais rien pour TransferPlaylistOwnership :
-- cette RPC n'existait pas encore quand l'enum a ete ecrit.
--
-- Pas de valeur pour DeletePlaylist, volontairement : playlist_ops est un
-- flux de fan-out temps reel pour une playlist encore vivante (docs/data-
-- model.md 9.2), pas un journal d'audit (activity_logs, 00014, joue deja ce
-- role) -- et un client qui se reconnecte APRES la suppression ne peut de
-- toute facon plus resoudre playlist_public_id (deleted_at IS NULL filtre
-- deja GetPlaylistIDByPublicID), donc jamais lire l'op qui l'annoncerait.
-- Voir le commentaire de DeletePlaylist (internal/playlist/service.go).
--
-- Meme geste que 00016_oauth_intra42.sql : ALTER TYPE ... ADD VALUE ne tourne
-- pas dans une transaction, d'ou l'annotation NO TRANSACTION. Pas de Down
-- pour la meme raison -- PostgreSQL ne sait pas retirer une valeur d'enum.

-- +goose NO TRANSACTION

-- +goose Up
ALTER TYPE playlist_op_type ADD VALUE IF NOT EXISTS 'ownership_transfer';

-- +goose Down
SELECT 1;
