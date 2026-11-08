"""docs/permissions.md §11/§12 : les deux "still checked in Go" que le
graphe ne peut pas porter (events.status change à chaque pause, ce serait
une écriture de tuple par action de lecture) --

  - can_vote / can_suggest_song : events.status IN ('scheduled', 'live')
  - can_control_playback : events.status = 'live'

Chacun avait un placeholder (internal/event/access.go) ou n'était vérifié
nulle part (internal/event/playback.go) avant docs/todo.md §3."""


def test_cannot_suggest_or_vote_in_an_ended_event(make_user, make_song, create_event, set_event_status, end_event, suggest):
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    set_event_status(event_id, "live")
    end_event(event_id, host)

    status, _ = suggest(event_id, host, make_song())
    assert status == 400


def test_cannot_control_playback_of_a_scheduled_event(make_user, create_event, set_playback):
    """Un event 'scheduled' n'a jamais eu de morceau en cours -- rien à
    mettre en pause ou repositionner. Contrairement à PlayNextInEventQueue
    (voir test_first_suggestion_promotes_scheduled_to_live), SetEventPlayback
    ne démarre jamais rien lui-même, donc reste bloqué ici."""
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])

    status, _ = set_playback(event_id, host, is_paused=True, position_ms=0)
    assert status == 400


def test_cannot_control_playback_of_an_ended_event(
    make_user, make_song, create_event, set_event_status, suggest, end_event, set_playback, play_next):
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    set_event_status(event_id, "live")
    suggest(event_id, host, make_song())
    end_event(event_id, host)

    status, _ = set_playback(event_id, host, is_paused=True, position_ms=0)
    assert status == 400
    status, _ = play_next(event_id, host)
    assert status == 400


def test_first_play_promotes_scheduled_to_live(
    make_user, make_song, create_event, suggest, play_next, get_event):
    """L'événement reste 'scheduled' jusqu'à ce qu'un morceau démarre
    réellement -- une suggestion ne suffit pas (rien ne démarre tout seul,
    D3), mais le premier play de l'hôte promeut le statut : c'est la seule
    façon de passer en 'live'."""
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    assert body["event"]["status"] == "scheduled"

    status, _ = suggest(event_id, host, make_song())
    assert status == 200
    status, body = get_event(event_id, host)
    assert body["event"]["status"] == "scheduled"

    status, body = play_next(event_id, host)
    assert status == 200

    status, body = get_event(event_id, host)
    assert status == 200
    assert body["event"]["status"] == "live"
