-- Un evenement n'a plus de statut "en pause" : la pause est celle de la musique
-- (SetEventPlayback, event_playback_states.is_paused), et l'evenement reste
-- live. PauseEvent/ResumeEvent ont ete retires ; plus rien ne mettait un
-- evenement en `paused`, seuls le seed et les donnees d'avant en avaient.
--
-- Les evenements `paused` passent `live` : leur musique, elle, reste en pause
-- (is_paused n'est pas touche), donc rien ne change pour qui les regarde.
--
-- Postgres ne sait pas retirer une valeur d'un enum : le type est recree sans
-- elle, et la colonne convertie (seule events.status l'utilise).

-- +goose Up
UPDATE events SET status = 'live' WHERE status = 'paused';

ALTER TYPE event_status RENAME TO event_status_with_paused;
CREATE TYPE event_status AS ENUM ('scheduled', 'live', 'ended');
ALTER TABLE events
    ALTER COLUMN status DROP DEFAULT,
    ALTER COLUMN status TYPE event_status USING status::text::event_status,
    ALTER COLUMN status SET DEFAULT 'scheduled';
DROP TYPE event_status_with_paused;

-- +goose Down
ALTER TYPE event_status RENAME TO event_status_without_paused;
CREATE TYPE event_status AS ENUM ('scheduled', 'live', 'paused', 'ended');
ALTER TABLE events
    ALTER COLUMN status DROP DEFAULT,
    ALTER COLUMN status TYPE event_status USING status::text::event_status,
    ALTER COLUMN status SET DEFAULT 'scheduled';
DROP TYPE event_status_without_paused;
