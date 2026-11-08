-- Avatar lookups for profile views (docs/data-model.md 6).

-- name: GetImageByID :one
SELECT id, storage_key
FROM images
WHERE id = $1;

-- One row per stored file (original upload, or a derived variant produced
-- by the Rust image-service -- see internal/media/client.go). The CHECK
-- constraint images_variant_source_check requires source_image_id on every
-- non-original row, so UploadAvatar always inserts the original first.
-- name: CreateImage :one
INSERT INTO images (owner_user_id, storage_key, content_type, width, height, byte_size, variant, source_image_id)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
RETURNING *;

-- Returns source_image_id so the caller can walk from a variant back to its
-- original and delete both rows (and both files) in one replacement --
-- see internal/user/service.go:UploadAvatar, which does this twice (the old
-- thumb, then the old original it points to).
--
-- public_id and owner_user_id are returned for the tuple deletion. An OpenFGA
-- tuple is removed by naming its three parts in full and the graph is not
-- queryable from the write path, so the only moment these values are available
-- is the statement that destroys the row -- read them here or lose them, and a
-- surviving playlist_cover_of tuple keeps granting can_view on an image whose
-- file is already gone.
-- name: DeleteImage :one
DELETE FROM images
WHERE id = $1
RETURNING public_id, owner_user_id, storage_key, source_image_id;
