-- Une licence vaut pour un evenement, jamais pour tous (V.2.2 : "give the music
-- control to different friends", ici pour une soiree, pas pour toujours).
--
-- GrantDeviceControl exige desormais l'evenement. Les licences permanentes
-- (event_id NULL) encore actives que les versions precedentes ont ecrites sont
-- revoquees, pas supprimees : revoked_at garde la trace de qui pouvait piloter
-- quoi, et quand. La contrainte empeche qu'une nouvelle soit ecrite.
--
-- Leurs tuples OpenFGA restent : la migration n'a pas acces a l'outbox. Elles ne
-- decident rien, canControlPlayback lit la licence en SQL
-- (ResolveDeviceControlLicense, qui ne voit plus que celle de l'evenement), et
-- make seed-reset les efface.

-- +goose Up
UPDATE device_control_licenses
SET revoked_at = NOW()
WHERE event_id IS NULL
  AND revoked_at IS NULL;

ALTER TABLE device_control_licenses
    ADD CONSTRAINT device_control_licenses_for_an_event_check
    CHECK (event_id IS NOT NULL OR revoked_at IS NOT NULL);

-- +goose Down
ALTER TABLE device_control_licenses DROP CONSTRAINT device_control_licenses_for_an_event_check;
