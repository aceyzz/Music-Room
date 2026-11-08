"""RegisterDevice : un même device_identifier réutilise toujours la même
ligne (upsert), pas d'accumulation de doublons."""


def test_upserts_by_identifier(make_user, register_device, list_my_devices):
    """Le client mobile envoie le même device_identifier (généré une fois à
    l'installation) à chaque enregistrement -- typiquement à chaque
    connexion. Ré-enregistrer un appareil déjà connu doit mettre à jour la
    même ligne (même id renvoyé), pas en créer une deuxième : sinon
    ListMyDevices se remplirait de doublons du même téléphone au fil des
    connexions."""
    user = make_user()
    status, body = register_device(user, identifier="stable-id")
    assert status == 200
    device_id = int(body["device"]["id"])
    assert body["device"]["isActive"] is True

    # Same identifier again: same row, updated in place, not a duplicate.
    status, body = register_device(user, identifier="stable-id")
    assert status == 200
    assert int(body["device"]["id"]) == device_id

    status, body = list_my_devices(user)
    assert status == 200
    assert len(body["devices"]) == 1


def test_list_my_devices_when_none_registered_is_empty(make_user, list_my_devices):
    """Un utilisateur qui n'a jamais enregistré d'appareil doit voir une
    liste vide, pas une erreur -- cas limite trivial mais qui vaut le coup
    d'être explicite (première utilisation de l'app, avant tout
    RegisterDevice)."""
    user = make_user()
    status, body = list_my_devices(user)
    assert status == 200
    assert body["devices"] == []


def test_binds_the_session_and_logs_against_the_device(
    make_user, api, public_id_of, auth_headers, db_conn, eventually
):
    """RegisterDevice rattache la session appelante à l'appareil
    (AttachSessionDevice) : chaque appel suivant de cette session est
    journalisé (V.6) avec device_id, et CreateActivityLog en recopie la
    plateforme et la version de l'app -- sans en-tête ni requête de plus."""
    user = make_user()
    status, body = api.post(
        f"/v1/users/{public_id_of(user)}/devices",
        json={
            "device_identifier": "bound-device",
            "name": "Test Device",
            "platform": "android",
            "app_version": "2.3.1",
        },
        headers=auth_headers(user),
    )
    assert status == 200
    device_id = int(body["device"]["id"])

    with db_conn.cursor() as cur:
        cur.execute("SELECT device_id FROM user_sessions WHERE user_id = %s", (user,))
        assert cur.fetchone()[0] == device_id

    action = "/music_room.v1.DelegationService/ListMyDevices"
    status, _ = api.get(f"/v1/users/{public_id_of(user)}/devices", headers=auth_headers(user))
    assert status == 200

    def latest():
        with db_conn.cursor() as cur:
            cur.execute(
                "SELECT device_id, platform_snapshot, app_version_snapshot FROM activity_logs "
                "WHERE action = %s AND user_id = %s ORDER BY created_at DESC LIMIT 1",
                (action, user),
            )
            return cur.fetchone()

    row = eventually(lambda: (latest(),), lambda row: row is not None)[0]
    assert row == (device_id, "android", "2.3.1")
