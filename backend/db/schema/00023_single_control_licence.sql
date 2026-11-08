-- One licence, one permission: a delegate drives the whole player of the event
-- (play / pause, next, seek). The per-action columns were never offered by the
-- API nor read by the check (event/access.go canControlPlayback), so they go.
--
-- The licence leaves the graph too (authz/model.fga): its tuples were written
-- but never read, and could not be right -- a tuple is unique per (friend,
-- device), a friend may hold one licence per event on the same device. Those
-- already written stay in the store, under relations the model no longer has:
-- nothing can reach them.

-- +goose Up
ALTER TABLE device_control_licenses
    DROP COLUMN can_play_pause,
    DROP COLUMN can_skip,
    DROP COLUMN can_seek,
    DROP COLUMN can_change_song,
    DROP COLUMN can_set_volume;

-- +goose Down
ALTER TABLE device_control_licenses
    ADD COLUMN can_play_pause  BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN can_skip        BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN can_seek        BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN can_change_song BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN can_set_volume  BOOLEAN NOT NULL DEFAULT FALSE;
