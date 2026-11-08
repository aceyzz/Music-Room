"""MoveSongInPlaylist (docs/todo.md §2) : déplace un morceau juste après un
autre (`after_playlist_song_id`, 0 = en tête). Pas de `base_revision` : une
playlist partagée change tout le temps, donc une requête est appliquée sur
l'ordre courant plutôt que refusée dès que quelqu'un d'autre l'a modifiée
entre-temps. Le seul refus est NOT_FOUND, quand le morceau déplacé ou son
ancre a disparu entre-temps (voir backend/db/query/playlists.sql,
MovePlaylistSong)."""


def test_moves_a_song_after_another(make_user, make_song, create_playlist, add_song, move_song):
    owner = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])

    ids = []
    for _ in range(3):
        status, body = add_song(playlist_id, make_song(), owner)
        ids.append(int(body["songs"][-1]["id"]))
    a, b, c = ids
    assert int(body["playlist"]["revision"]) == 3

    # A, B, C -> B, A, C (A après B).
    status, body = move_song(playlist_id, a, after_playlist_song_id=b, user_id=owner)
    assert status == 200
    assert [int(s["id"]) for s in body["songs"]] == [b, a, c]
    assert int(body["playlist"]["revision"]) == 4
    # Les positions renvoyées restent un rang 1..n, même si le score interne
    # est une NUMERIC fractionnaire ((a + b) * 0.5).
    assert [s["position"] for s in body["songs"]] == [1, 2, 3]


def test_moves_a_song_to_the_top(make_user, make_song, create_playlist, add_song, move_song):
    owner = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])
    ids = []
    for _ in range(3):
        status, body = add_song(playlist_id, make_song(), owner)
        ids.append(int(body["songs"][-1]["id"]))
    a, b, c = ids

    # A, B, C -> C, A, B (C en tête, after_playlist_song_id=0).
    status, body = move_song(playlist_id, c, after_playlist_song_id=0, user_id=owner)
    assert status == 200
    assert [int(s["id"]) for s in body["songs"]] == [c, a, b]


def test_moving_a_song_after_itself_is_rejected(make_user, make_song, create_playlist, add_song, move_song):
    owner = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])
    _, body = add_song(playlist_id, make_song(), owner)
    a = int(body["songs"][0]["id"])

    status, _ = move_song(playlist_id, a, after_playlist_song_id=a, user_id=owner)
    assert status == 400  # INVALID_ARGUMENT


def test_unknown_playlist_song_id_is_not_found(make_user, create_playlist, move_song):
    owner = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])

    status, _ = move_song(playlist_id, 999_999_999, after_playlist_song_id=0, user_id=owner)
    assert status == 404


def test_unknown_anchor_is_not_found(make_user, make_song, create_playlist, add_song, move_song):
    owner = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])
    _, body = add_song(playlist_id, make_song(), owner)
    a = int(body["songs"][0]["id"])

    status, _ = move_song(playlist_id, a, after_playlist_song_id=999_999_999, user_id=owner)
    assert status == 404


def test_non_member_cannot_move_a_song(make_user, make_song, create_playlist, add_song, move_song):
    """add_song / remove_song / move_song sont une seule permission
    (authz/model.fga) : ce qui refuse déjà AddSongToPlaylist à un outsider
    refuse aussi le déplacement."""
    owner = make_user()
    outsider = make_user()
    _, body = create_playlist(owner, edit_license="invited_only")
    playlist_id = int(body["playlist"]["id"])
    _, body = add_song(playlist_id, make_song(), owner)
    a = int(body["songs"][0]["id"])

    status, _ = move_song(playlist_id, a, after_playlist_song_id=0, user_id=outsider)
    assert status == 403
