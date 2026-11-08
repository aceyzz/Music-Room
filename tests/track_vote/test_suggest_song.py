"""SuggestSong : un morceau ne peut être en file qu'une fois à la fois, et
suggérer un morceau ne doit jamais couper ce qui joue déjà."""


def test_suggesting_the_same_song_twice_is_rejected(make_user, make_song, create_event, suggest):
    """La contrainte unique event_queue_entries_one_active_per_song empêche
    un même morceau d'apparaître deux fois dans la file (statuts 'queued' ou
    'playing') d'un même event -- la deuxième tentative doit remonter comme
    un conflit (409 AlreadyExists), pas comme un doublon silencieux."""
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    song = make_song()

    status, _ = suggest(event_id, host, song)
    assert status == 200

    # Même morceau, même event : refusé.
    status, _ = suggest(event_id, host, song)
    assert status == 409  # AlreadyExists


def test_suggesting_to_a_playing_event_does_not_restart_it(
    make_user, make_song, create_event, suggest, play_next, get_playback
):
    """Une suggestion qui arrive pendant qu'un morceau joue déjà doit
    simplement rejoindre la file, sans jamais interrompre ou remplacer ce
    qui est en train de jouer."""
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])

    first_song = make_song()
    status, _ = suggest(event_id, host, first_song)
    assert status == 200
    status, body = play_next(event_id, host)  # l'hôte lance la radio (D3).
    assert int(body["playback"]["currentSong"]["id"]) == first_song["id"]

    # A second suggestion arrives while the radio is already playing: it must
    # join the queue, not replace what's currently playing.
    second_song = make_song()
    status, body = suggest(event_id, host, second_song)
    assert status == 200
    assert body.get("playback") is None  # a suggestion never touches playback.

    # Le morceau en cours de lecture n'a pas changé.
    status, body = get_playback(event_id, host)
    assert int(body["playback"]["currentSong"]["id"]) == first_song["id"]
