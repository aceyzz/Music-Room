"""Une délégation vaut pour UN événement, jamais pour tous (00021) : le
serveur refuse un don sans événement, et une ancienne licence permanente ne
donne plus aucun contrôle. Et révoquer une délégation doit vraiment couper
l'accès, pas seulement disparaître de la liste (voir test_revoking.py pour la
vérification côté liste)."""


def test_a_grant_for_every_event_is_refused(make_user, make_friendship, register_device, grant_control):
    """GrantDeviceControl sans event_public_id ("standing grant", "tu peux
    piloter mon enceinte, toujours") : refusé (400), il n'y a pas de licence
    pour tous les événements."""
    host = make_user()
    friend = make_user()
    make_friendship(host, friend)
    _, body = register_device(host)
    device_id = int(body["device"]["id"])

    status, _ = grant_control(device_id, host, friend, standing=True)
    assert status == 400


def test_an_old_standing_licence_controls_nothing(
    db_conn, make_user, make_friendship, make_song, register_device, create_event, suggest,
    play_next, set_event_playback,
):
    """Une licence permanente écrite avant 00021 (event_id NULL) ne compte plus :
    ResolveDeviceControlLicense ne voit que la licence de l'événement. Elle est
    insérée directement, déjà révoquée comme 00021 l'a fait : la contrainte
    interdit qu'elle soit encore active."""
    host = make_user()
    friend = make_user()
    make_friendship(host, friend)
    _, body = register_device(host)
    device_id = int(body["device"]["id"])
    _, event_body = create_event(host, name="After the migration")
    event_id = int(event_body["event"]["id"])
    suggest(event_id, host, make_song())
    play_next(event_id, host)

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO device_control_licenses (device_id, grantee_user_id, granted_by_id, revoked_at) "
            "VALUES (%s, %s, %s, NOW())",
            (device_id, friend, host),
        )

    status, _ = set_event_playback(event_id, friend, is_paused=True)
    assert status == 403


def test_a_live_standing_licence_cannot_be_written(db_conn, make_user, make_friendship, register_device):
    """La contrainte de 00021 : une licence sans événement ne peut exister que
    révoquée (la trace d'avant), jamais active."""
    import psycopg2.errors

    host = make_user()
    friend = make_user()
    make_friendship(host, friend)
    _, body = register_device(host)
    device_id = int(body["device"]["id"])

    try:
        with db_conn.cursor() as cur:
            cur.execute(
                "INSERT INTO device_control_licenses (device_id, grantee_user_id, granted_by_id) "
                "VALUES (%s, %s, %s)",
                (device_id, friend, host),
            )
        raise AssertionError("a live licence with no event was written")
    except psycopg2.errors.CheckViolation:
        pass


def test_revoking_removes_playback_control(
    make_user, make_friendship, make_song, register_device, grant_control, create_event, suggest,
    play_next, set_event_playback, revoke_control, eventually,
):
    """Complément fonctionnel de test_revoking.py::test_grant_then_revoke_round_trip
    (qui ne vérifie que la liste des délégations) : ici on prouve que la
    révocation a un EFFET réel -- l'ami contrôle la lecture avant, puis se
    fait refuser (403) exactement la même action juste après la révocation,
    sur le même event."""
    host = make_user()
    friend = make_user()
    make_friendship(host, friend)
    _, body = register_device(host)
    device_id = int(body["device"]["id"])

    _, event_body = create_event(host, name="Revocable")
    event_id = int(event_body["event"]["id"])
    _, license_body = grant_control(device_id, host, friend, event_id=event_id)
    license_id = int(license_body["license"]["id"])
    suggest(event_id, host, make_song())
    play_next(event_id, host)  # l'hôte appuie sur lecture : rien ne démarre tout seul (D3).

    # Avant révocation : l'ami contrôle la lecture normalement (la tuple du
    # don passe par l'outbox, asynchrone -- voir tests/conftest.py:eventually).
    status, _ = eventually(
        lambda: set_event_playback(event_id, friend, is_paused=True),
        lambda status, _: status == 200,
    )
    assert status == 200

    status, _ = revoke_control(device_id, license_id, host)
    assert status == 200

    # Après révocation, la même action est refusée.
    status, _ = eventually(
        lambda: set_event_playback(event_id, friend, is_paused=False),
        lambda status, _: status == 403,
    )
    assert status == 403
