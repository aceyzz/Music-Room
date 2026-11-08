"""Piloter la radio (pause/skip) est réservé à l'hôte, ou à un appareil
délégué -- voir tests/control_delegation/test_playback_delegation.py pour le
scénario complet de délégation."""


def test_requires_host_or_delegation(
    make_user, make_song, create_event, suggest, set_playback, play_next
):
    """Sans device_id délégué (V.2.2), seul l'hôte peut agir sur la lecture :
    ni SetEventPlayback (pause/reprise/seek) ni PlayNextInEventQueue (skip)
    ne doivent accepter un utilisateur quelconque. Ce test ne couvre que le
    cas "pas de délégation du tout" -- le cas où quelqu'un a reçu une
    délégation valide est dans control_delegation/test_playback_delegation.py."""
    host = make_user()
    stranger = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    suggest(event_id, host, make_song())
    play_next(event_id, host)  # l'hôte appuie sur lecture : rien ne démarre tout seul (D3).

    # Un inconnu ne peut pas mettre en pause...
    status, _ = set_playback(event_id, stranger, is_paused=True)
    assert status == 403

    # ...alors que l'hôte le peut.
    status, body = set_playback(event_id, host, is_paused=True)
    assert status == 200
    assert body["playback"]["isPaused"] is True

    # Même chose pour "passer au morceau suivant".
    status, _ = play_next(event_id, stranger)
    assert status == 403


def test_pausing_keeps_the_current_song(
    make_user, make_song, create_event, suggest, play_next, set_playback
):
    """La réponse d'une pause porte toujours le morceau en cours. Sans lui,
    l'app lisait "rien ne joue", et son bouton lecture lançait le morceau
    SUIVANT au lieu de reprendre celui-ci : pause puis lecture sautait une
    musique."""
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    suggest(event_id, host, make_song())
    suggest(event_id, host, make_song())
    play_next(event_id, host)  # l'hôte appuie sur lecture : rien ne démarre tout seul (D3).

    status, body = set_playback(event_id, host, is_paused=True)
    assert status == 200
    paused_song = body["playback"].get("currentSong")
    assert paused_song, "a paused answer must still carry the song"

    status, body = set_playback(event_id, host, is_paused=False)
    assert status == 200
    assert body["playback"]["currentSong"]["deezerSongId"] == paused_song["deezerSongId"]
