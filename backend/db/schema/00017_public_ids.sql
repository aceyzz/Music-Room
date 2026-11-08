-- Public UUIDs for the three tables that still lacked one (docs/data-model.md 15).
--
-- Required by the permission graph, not by the API surface. An OpenFGA object is
-- named "<type>:<id>", and that id has to be the value the client already sent --
-- otherwise every Check needs a public-to-internal lookup in Postgres first, a
-- database round trip on the hot path of the system whose whole purpose is to
-- avoid one. So `device`, `image` and `queue_entry` tuples were unwritable until
-- these columns existed: half the model, including all of control delegation.
--
-- Same reasoning as users.public_id (00004): the API exposes only the UUID, so
-- sequential ids are never enumerable by a client. gen_random_uuid() is volatile,
-- so each ALTER rewrites its table and every existing row gets a distinct value.
--
-- No index beyond the UNIQUE constraint. The constraint's index is what lookups by
-- public id use, and nothing here is read by public id often enough to want more.

-- +goose Up
ALTER TABLE devices
    ADD COLUMN public_id UUID NOT NULL DEFAULT gen_random_uuid();

ALTER TABLE devices
    ADD CONSTRAINT devices_public_id_key UNIQUE (public_id);

ALTER TABLE images
    ADD COLUMN public_id UUID NOT NULL DEFAULT gen_random_uuid();

ALTER TABLE images
    ADD CONSTRAINT images_public_id_key UNIQUE (public_id);

-- Queue entries are the one case where the id is short-lived: an entry is created
-- by a suggestion and dies with the event. It still needs a public id, because
-- `queue_entry#can_remove` is checked on a specific entry the client names.
ALTER TABLE event_queue_entries
    ADD COLUMN public_id UUID NOT NULL DEFAULT gen_random_uuid();

ALTER TABLE event_queue_entries
    ADD CONSTRAINT event_queue_entries_public_id_key UNIQUE (public_id);

-- +goose Down
ALTER TABLE event_queue_entries
    DROP CONSTRAINT IF EXISTS event_queue_entries_public_id_key;

ALTER TABLE event_queue_entries
    DROP COLUMN IF EXISTS public_id;

ALTER TABLE images
    DROP CONSTRAINT IF EXISTS images_public_id_key;

ALTER TABLE images
    DROP COLUMN IF EXISTS public_id;

ALTER TABLE devices
    DROP CONSTRAINT IF EXISTS devices_public_id_key;

ALTER TABLE devices
    DROP COLUMN IF EXISTS public_id;
