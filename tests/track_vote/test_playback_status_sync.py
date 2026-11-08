"""GetEventPlayback.is_paused n'est pas un miroir brut de la colonne
event_playback_states.is_paused : il est vrai aussi dès que l'événement
n'est pas 'live' (scheduled, ended) -- dérivé à la lecture
(playbackStateDTO, internal/event/playback.go), pas synchronisé à
l'écriture. Sans ça, un event terminé afficherait isPaused=false, laissant
un client extrapoler la position du morceau indéfiniment
(EventPlaybackDTO : "position_ms + (now - updated_at) when not paused")."""


def test_ending_the_event_reports_playback_as_paused(
    make_user, make_song, create_event, set_event_status, suggest, end_event, get_playback):
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    set_event_status(event_id, "live")
    suggest(event_id, host, make_song())

    status, _ = end_event(event_id, host)
    assert status == 200

    status, body = get_playback(event_id, host)
    assert status == 200
    assert body["playback"]["isPaused"] is True
