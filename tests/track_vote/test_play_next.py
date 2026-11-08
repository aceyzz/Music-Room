"""PlayNextInEventQueue : avancer manuellement la file (l'hôte "skip"), et ce
qui se passe quand il n'y a plus rien à jouer. Complète test_radio.py, qui
teste le même mécanisme d'arrêt/redémarrage mais déclenché par le vrai
minuteur (donc lent, ~3s) -- ici tout est déclenché à la main, donc rapide et
déterministe."""


def test_host_can_skip_to_the_next_song(
    make_user, make_song, create_event, suggest, play_next
):
    """L'hôte peut passer au morceau suivant avant même que le morceau en
    cours soit terminé (un vrai "skip", pas juste l'avance automatique en
    fin de morceau) : le morceau sauté est marqué joué et disparaît de la
    file, celui d'après devient "current"."""
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    first_song = make_song()
    second_song = make_song()
    suggest(event_id, host, first_song)
    suggest(event_id, host, second_song)
    play_next(event_id, host)  # l'hôte lance la radio : first_song devient "current".

    status, body = play_next(event_id, host)
    assert status == 200
    assert int(body["playback"]["currentSong"]["id"]) == second_song["id"]
    # The song that was skipped is gone from the queue (it's "played" now),
    # and nothing else was queued behind it.
    assert body["queue"] == []


def test_skip_with_nothing_queued_fails_and_leaves_playback_untouched(
    make_user, create_event, play_next, get_playback
):
    """Demander explicitement "morceau suivant" alors qu'il n'y a jamais eu
    de morceau du tout (rien ne joue, rien n'est en file) doit échouer
    proprement (400, la file est vide) sans modifier l'état de lecture --
    pas de morceau "current" à effacer puisqu'il n'y en avait pas."""
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])

    status, _ = play_next(event_id, host)
    assert status == 400  # FailedPrecondition: "the queue is empty"

    status, body = get_playback(event_id, host)
    assert status == 200
    assert int(body["playback"]["currentQueueEntryId"]) == 0


def test_radio_stays_silent_when_a_song_is_suggested_after_the_queue_ran_dry(
    make_user, make_song, create_event, suggest, play_next, get_playback
):
    """Version rapide (sans attendre de vrai temps, contrairement à
    test_radio.py) du scénario "la radio s'arrête proprement" : on force
    l'arrêt en demandant explicitement "morceau suivant" alors que la file
    est vide, puis on vérifie qu'une nouvelle suggestion ne relance PAS la
    lecture toute seule -- seul l'hôte la relance (docs/todo.md §4, D3)."""
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    suggest(event_id, host, make_song())
    play_next(event_id, host)  # becomes "current", queue now empty

    # Explicit skip with nothing queued behind it: the radio stops cleanly
    # (current_song cleared) instead of leaving a finished song looking
    # "current" forever.
    status, _ = play_next(event_id, host)
    assert status == 400

    status, body = get_playback(event_id, host)
    assert body["playback"]["currentSong"] is None
    assert body["playback"]["isPaused"] is True

    # A new suggestion joins the queue and nothing starts: the host plays it.
    status, body = suggest(event_id, host, make_song())
    assert status == 200
    assert body.get("playback") is None
    assert len(body["queue"]) == 1

    status, body = play_next(event_id, host)
    assert status == 200
    assert body["playback"]["currentSong"] is not None
