-- +goose Up
ALTER TABLE user_tokens DROP CONSTRAINT user_tokens_token_hash_key;
ALTER TABLE user_tokens ADD COLUMN attempts SMALLINT NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE user_tokens DROP COLUMN attempts;
ALTER TABLE user_tokens ADD CONSTRAINT user_tokens_token_hash_key UNIQUE (token_hash);
