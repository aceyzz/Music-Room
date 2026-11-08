"""ListPlaylists (docs/todo.md §2) : toute playlist visible par l'appelant --
les siennes (n'importe quel rôle) + les publiques de tout le monde. Passe par
OpenFGA ListObjects(can_view), jamais un WHERE Go -- c'est exactement ce que
ce fichier vérifie : aucune playlist privée d'un tiers ne doit apparaître."""


def _ids(body):
    return {int(p["id"]) for p in body["playlists"]}


def test_lists_own_playlists_regardless_of_visibility(
    make_user, create_playlist, list_playlists, eventually
):
    owner = make_user()
    _, private = create_playlist(owner, visibility="private")
    _, public = create_playlist(owner, visibility="public")
    private_id = int(private["playlist"]["id"])
    public_id = int(public["playlist"]["id"])

    status, body = eventually(
        lambda: list_playlists(owner),
        lambda status, body: status == 200 and {private_id, public_id} <= _ids(body),
    )
    assert status == 200
    assert {private_id, public_id} <= _ids(body)


def test_sees_public_playlists_of_others_but_not_private_ones(
    make_user, create_playlist, list_playlists, eventually
):
    owner = make_user()
    stranger = make_user()
    _, private = create_playlist(owner, visibility="private")
    _, public = create_playlist(owner, visibility="public")
    private_id = int(private["playlist"]["id"])
    public_id = int(public["playlist"]["id"])

    status, body = eventually(
        lambda: list_playlists(stranger),
        lambda status, body: status == 200 and public_id in _ids(body),
    )
    assert status == 200
    assert public_id in _ids(body)
    assert private_id not in _ids(body)


def test_member_sees_the_private_playlist_they_were_invited_to(
    make_user, create_playlist, invite_to_playlist, list_playlists, eventually
):
    owner = make_user()
    member = make_user()
    _, body = create_playlist(owner, visibility="private")
    playlist_id = int(body["playlist"]["id"])
    invite_to_playlist(playlist_id, owner, member)

    status, body = eventually(
        lambda: list_playlists(member),
        lambda status, body: status == 200 and playlist_id in _ids(body),
    )
    assert status == 200
    assert playlist_id in _ids(body)


def test_deleted_playlist_disappears_from_the_listing(
    make_user, create_playlist, delete_playlist, list_playlists, eventually
):
    owner = make_user()
    _, body = create_playlist(owner, visibility="public")
    playlist_id = int(body["playlist"]["id"])
    eventually(
        lambda: list_playlists(owner),
        lambda status, body: status == 200 and playlist_id in _ids(body),
    )

    status, _ = delete_playlist(playlist_id, owner)
    assert status == 200

    status, body = list_playlists(owner)
    assert status == 200
    assert playlist_id not in _ids(body)
