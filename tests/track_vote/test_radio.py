"""La radio avance toute seule (minuteur serveur, scheduler.go) et s'arrête
proprement quand la file se vide, plutôt que de rester bloquée sur un
morceau fini. Ces deux tests attendent réellement la fin d'un morceau (durée
raccourcie à 2s pour le test, +1s de marge) : ~3s chacun, d'où le marqueur
`slow` -- `pytest -m "not slow"` pour les sauter en boucle rapide.

Pour un test rapide et déterministe du même mécanisme (arrêt propre +
redémarrage), sans attendre de vrai temps, voir
track_vote/test_play_next.py::test_radio_restarts_when_a_song_is_suggested_after_the_queue_ran_dry
qui déclenche l'arrêt manuellement via PlayNextInEventQueue plutôt que
d'attendre le minuteur."""

import time

import pytest

pytestmark = pytest.mark.slow


def test_auto_advances_when_the_current_song_ends(
    make_user, make_song, create_event, suggest, play_next, get_playback
):
    """Personne n'appelle PlayNextInEventQueue : c'est le minuteur côté
    serveur, programmé sur la durée du morceau en cours, qui doit faire
    avancer la file tout seul quand le morceau se termine -- sinon la radio
    resterait bloquée sur le premier morceau indéfiniment."""
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    short_song = make_song(duration_seconds=2)  # assez court pour ne pas ralentir la suite.
    next_song = make_song()

    status, _ = suggest(event_id, host, short_song)
    assert status == 200
    status, body = play_next(event_id, host)  # l'hôte lance la radio (D3).
    assert int(body["playback"]["currentSong"]["id"]) == short_song["id"]

    suggest(event_id, host, next_song)  # reste en file, prêt à prendre le relais.

    time.sleep(3)  # laisse le minuteur (2s) se déclencher, avec de la marge.

    status, body = get_playback(event_id, host)
    assert status == 200
    assert int(body["playback"]["currentSong"]["id"]) == next_song["id"]


def test_stops_cleanly_when_the_queue_runs_dry(
    make_user, make_song, create_event, suggest, get_playback
):
    """Quand le morceau en cours se termine et qu'il n'y a plus rien en
    file, la radio doit afficher "rien ne joue" (current_song vidé, en
    pause) plutôt que de rester affichée comme "en train de jouer" un
    morceau déjà fini -- ce qui ferait dériver indéfiniment la position
    calculée côté client (position_ms + temps écoulé depuis updated_at)."""
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    only_song = make_song(duration_seconds=2)

    suggest(event_id, host, only_song)  # rien d'autre en file derrière.
    time.sleep(3)

    status, body = get_playback(event_id, host)
    assert status == 200
    playback = body["playback"]
    assert int(playback["currentQueueEntryId"]) == 0
    assert playback["currentSong"] is None
    assert playback["isPaused"] is True
