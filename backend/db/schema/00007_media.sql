-- Uploaded images and the variants derived by the Rust image-service
-- (docs/data-model.md 6).
--
-- Created before user_profiles and playlists, both of which reference it.
-- source_image_id ties thumb/medium back to the original, so deleting an
-- original cascades to its variants.

-- +goose Up
CREATE TABLE images (
    id              BIGSERIAL   PRIMARY KEY,
    owner_user_id   BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    storage_key     TEXT        NOT NULL,
    content_type    TEXT        NOT NULL,
    width           INTEGER,
    height          INTEGER,
    byte_size       INTEGER,
    variant         TEXT        NOT NULL DEFAULT 'original',
    source_image_id BIGINT      REFERENCES images (id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT images_storage_key_key UNIQUE (storage_key),
    CONSTRAINT images_variant_check CHECK (variant IN ('original', 'thumb', 'medium')),
    -- an original has no source; a derived variant must have one
    CONSTRAINT images_variant_source_check CHECK (
        (variant = 'original' AND source_image_id IS NULL)
        OR (variant <> 'original' AND source_image_id IS NOT NULL)
    )
);

CREATE INDEX images_owner_user_id_idx ON images (owner_user_id);
CREATE INDEX images_source_image_id_idx ON images (source_image_id);

-- +goose Down
DROP TABLE IF EXISTS images;
