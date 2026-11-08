"""Le point d'intégration avec EventService : un appareil délégué peut piloter
la radio d'un événement, mais seulement dans la portée du don (permanent, ou
limité à un event précis). Pour le cas symétrique (délégation permanente,
valable sur tout event), voir test_standing_grant.py."""


def test_delegated_device_can_control_playback_but_only_for_its_scope(
    make_user, make_friendship, make_song, register_device, create_event, suggest,
    play_next, set_event_playback, grant_control, eventually,
):
    """Une délégation créée avec event_id=X (pas une délégation permanente)
    ne doit donner le contrôle QUE sur l'event X : ce test crée deux
    événements, vérifie qu'aucun n'est contrôlable par l'ami avant la
    délégation, accorde une délégation limitée au premier, puis vérifie que
    ça marche sur le premier mais échoue toujours sur le second -- la portée
    du don doit être respectée dans les deux sens, pas seulement "accordée
    quelque part = accordée partout"."""
    host = make_user()
    friend = make_user()
    make_friendship(host, friend)
    _, body = register_device(host)
    device_id = int(body["device"]["id"])

    _, event_body = create_event(host, name="Delegated")
    event_id = int(event_body["event"]["id"])
    _, other_event_body = create_event(host, name="Other event")
    other_event_id = int(other_event_body["event"]["id"])
    suggest(event_id, host, make_song())
    suggest(other_event_id, host, make_song())
    play_next(event_id, host)  # l'hôte appuie sur lecture : rien ne démarre tout seul (D3).
    play_next(other_event_id, host)

    # No delegation yet: the friend cannot touch either event's playback.
    status, _ = set_event_playback(event_id, friend, is_paused=True)
    assert status == 403

    # Grant scoped to `event_id` only (not a standing grant).
    status, _ = grant_control(device_id, host, friend, event_id=event_id)
    assert status == 200

    # Fonctionne sur l'event ciblé par la délégation (la tuple du don passe
    # par l'outbox, asynchrone -- voir tests/conftest.py:eventually)...
    status, body = eventually(
        lambda: set_event_playback(event_id, friend, is_paused=True),
        lambda status, _: status == 200,
    )
    assert status == 200
    assert body["playback"]["isPaused"] is True

    # The grant does not carry over to a different event.
    status, _ = set_event_playback(other_event_id, friend, is_paused=True)
    assert status == 403
