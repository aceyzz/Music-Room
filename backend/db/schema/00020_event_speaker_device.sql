-- L'appareil qui joue le son d'un evenement : l'enceinte (docs/todo.md §4, D1).
--
-- Fixe la premiere fois que l'hote appuie sur lecture, depuis l'appareil de sa
-- session (RegisterDevice le rattache) ; ensuite seul l'hote la change
-- (SetEventSpeaker, qui deplace aussi les licences de l'evenement). C'est contre
-- lui qu'une delegation est verifiee (V.2.2 : la licence est propre a chaque
-- appareil) : un ami pilote l'enceinte de l'hote, pas l'hote.
--
-- Pas controller_device_id (00012), qui existe deja et n'est jamais ecrit :
-- le "controleur" est celui qui a appuye en dernier et change a chaque
-- commande, l'enceinte ne change pas. Les confondre ferait passer le son sur le
-- telephone de chaque delegue qui appuie sur pause.
--
-- ON DELETE SET NULL : sans enceinte, seul l'hote pilote, et le prochain play
-- de l'hote en reprend une.

-- +goose Up
ALTER TABLE event_playback_states
    ADD COLUMN speaker_device_id BIGINT REFERENCES devices (id) ON DELETE SET NULL;

-- +goose Down
ALTER TABLE event_playback_states DROP COLUMN speaker_device_id;
