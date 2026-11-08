"""AddSongToPlaylist / RemoveSongFromPlaylist : effets sur les statistiques
(song_count, total_duration_seconds) et sur revision."""


def test_add_and_remove_bumps_revision_and_stats(
    make_user, make_song, create_playlist, add_song, remove_song
):
    """Chaque mutation de la playlist doit : (1) incrémenter `revision` d'1
    exactement -- c'est ce compteur qui permet à un client de savoir s'il a
    raté un changement, donc il ne doit ni sauter ni stagner -- et (2)
    maintenir song_count/total_duration_seconds en cohérence avec le
    contenu réel plutôt que de les recalculer à la demande."""
    owner = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])
    assert int(body["playlist"]["revision"]) == 0  # rien n'a encore été modifié.

    song = make_song(duration_seconds=42)
    status, body = add_song(playlist_id, song, owner)
    assert status == 200
    assert int(body["playlist"]["revision"]) == 1
    assert body["playlist"]["songCount"] == 1
    assert body["playlist"]["totalDurationSeconds"] == 42
    playlist_song_id = int(body["songs"][0]["id"])

    status, body = remove_song(playlist_id, playlist_song_id, owner)
    assert status == 200
    assert int(body["playlist"]["revision"]) == 2  # une deuxième mutation, une deuxième bump.
    assert body["playlist"]["songCount"] == 0
    assert body["playlist"]["totalDurationSeconds"] == 0


def test_adding_the_same_song_twice_is_rejected(make_user, make_song, create_playlist, add_song):
    """Un même morceau ne peut pas être ajouté deux fois à la même
    playlist : la deuxième tentative doit remonter comme un conflit (409),
    pas comme un doublon silencieux dans la liste des morceaux."""
    owner = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])
    song = make_song()

    status, _ = add_song(playlist_id, song, owner)
    assert status == 200

    status, _ = add_song(playlist_id, song, owner)
    assert status == 409  # AlreadyExists


def test_songs_are_listed_in_the_order_they_were_added(
    make_user, make_song, create_playlist, add_song, get_playlist
):
    """AddSongToPlaylist ajoute toujours à la fin (position = max+1) : après
    trois ajouts successifs, GetPlaylist doit les rendre dans le même ordre
    qu'ils ont été ajoutés, pas dans un ordre arbitraire (ex. par id
    interne, qui coïnciderait ici mais ne devrait pas être ce qu'on teste)."""
    owner = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])
    songs = [make_song(), make_song(), make_song()]

    for song in songs:
        add_song(playlist_id, song, owner)

    status, body = get_playlist(playlist_id, owner)
    assert status == 200
    assert [int(s["song"]["id"]) for s in body["songs"]] == [song["id"] for song in songs]
