"""CreateEvent : valeurs par défaut et validation des paramètres."""


def test_defaults_to_public_everyone(api, make_user, create_event):
    """Le sujet est explicite : "By default, your event is public" et "By
    default, everyone can vote" -- si on ne précise ni visibility ni
    vote_license à la création, l'API doit appliquer ces deux défauts
    elle-même plutôt que de renvoyer une erreur "champ requis"."""
    host = make_user()
    status, body = create_event(host)
    assert status == 200
    event = body["event"]
    assert event["visibility"] == "public"
    assert event["voteLicense"] == "everyone"
    assert int(event["hostId"]) == host
    assert int(event["revision"]) == 0


def test_rejects_invalid_visibility(api, make_user, create_event):
    """Une valeur de visibility qui n'est ni "public" ni "private" doit être
    rejetée à la création (400), pas silencieusement acceptée ou retombée sur
    un défaut."""
    host = make_user()
    status, _ = create_event(host, visibility="bogus")
    assert status == 400


def test_location_time_requires_venue_fields(api, make_user, create_event):
    """La licence "location_time" a besoin d'un lieu et d'un créneau pour
    avoir un sens (sans ça, "vote autorisé si vous êtes au bon endroit à la
    bonne heure" ne veut rien dire) : la choisir sans fournir
    venue_latitude/venue_longitude/venue_radius_meters/vote_window_* doit
    échouer à la création plutôt que de créer un event à moitié configuré
    que la contrainte SQL rejettera plus tard de façon plus obscure."""
    host = make_user()
    status, _ = create_event(host, vote_license="location_time")
    assert status == 400


def test_seeds_the_queue_from_a_source_playlist_and_stays_silent(
    api, make_user, make_song, create_event, auth_headers, eventually
):
    """CreateEvent(source_playlist_id=...) copie les morceaux d'une playlist
    existante dans la file de vote, ce qui la rend non-vide dès la création
    -- mais la radio ne démarre pas : elle attend que l'hôte appuie sur
    lecture (docs/todo.md §4, D3)."""
    host = make_user()
    # Une playlist normale, créée via PlaylistService (V.2.3), avec deux
    # morceaux -- c'est elle que CreateEvent va copier dans la file de vote.
    # Pas de fixture create_playlist dans ce dossier (celle de
    # tests/playlist_editor n'est pas partagée entre répertoires de tests) :
    # appel direct, avec la même attente que create_playlist pour laisser le
    # temps à la tuple `owner` de la playlist de se synchroniser avant que
    # CreateEvent(source_playlist_public_id=...) ne la lise.
    status, playlist_body = api.post(
        "/v1/playlists", json={"name": "Source Mix"}, headers=auth_headers(host)
    )
    assert status == 200
    playlist_id = int(playlist_body["playlist"]["id"])
    playlist_public_id = playlist_body["playlist"]["publicId"]
    eventually(
        lambda: api.get(f"/v1/playlists/{playlist_public_id}", headers=auth_headers(host)),
        lambda status, _: status == 200,
    )
    song_a = make_song()
    song_b = make_song()
    api.post(
        f"/v1/playlists/{playlist_public_id}/songs",
        json={"deezer_song_id": song_a["deezer_song_id"]},
        headers=auth_headers(host),
    )
    api.post(
        f"/v1/playlists/{playlist_public_id}/songs",
        json={"deezer_song_id": song_b["deezer_song_id"]},
        headers=auth_headers(host),
    )

    status, body = create_event(host, source_playlist_public_id=playlist_public_id)
    assert status == 200
    assert int(body["event"]["sourcePlaylistId"]) == playlist_id
    # Rien ne joue : les deux morceaux copiés attendent dans la file.
    assert body.get("playback") is None
    assert len(body["queue"]) == 2


def test_seeding_from_a_playlist_you_cannot_view_is_denied(
    api, make_user, auth_headers, create_event, eventually
):
    """Souligné par le commentaire de policy.go sur CreateEvent : sans cette
    vérification, n'importe qui pourrait copier le contenu d'une playlist
    privée d'autrui dans un event public en s'en servant comme source --
    une fuite qui ne ressemble pas à une lecture. source_playlist_public_id
    porte NotFound:true (c'est une permission de lecture, PermPlaylistView),
    donc le refus est un 404, pas un 403 -- comme GetPlaylist sur la même
    playlist depuis le même point de vue."""
    stranger = make_user()
    host = make_user()
    status, playlist_body = api.post(
        "/v1/playlists",
        json={"name": "Stranger's Private Mix", "visibility": "private"},
        headers=auth_headers(stranger),
    )
    assert status == 200
    playlist_public_id = playlist_body["playlist"]["publicId"]
    eventually(
        lambda: api.get(f"/v1/playlists/{playlist_public_id}", headers=auth_headers(stranger)),
        lambda status, _: status == 200,
    )

    status, _ = create_event(host, source_playlist_public_id=playlist_public_id)
    assert status == 404
