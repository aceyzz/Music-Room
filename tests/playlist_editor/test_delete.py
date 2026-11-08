"""DeletePlaylist (docs/todo.md §2) : soft-delete (deleted_at), propriétaire
seulement -- can_delete n'inclut pas admin, contrairement à la plupart des
autres permissions de ce service."""


def test_owner_deletes_the_playlist(make_user, create_playlist, delete_playlist, get_playlist):
    owner = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])
    assert body["playlist"]["deletedAt"] == "0"

    status, body = delete_playlist(playlist_id, owner)
    assert status == 200
    assert body["playlist"]["deletedAt"] != "0"

    # deleted_at IS NULL filtre toute lecture -- la playlist devient
    # introuvable, y compris pour son propriétaire.
    status, _ = get_playlist(playlist_id, owner)
    assert status == 404


def test_admin_cannot_delete(
    make_user, create_playlist, invite_to_playlist, transfer_ownership, delete_playlist, eventually
):
    """can_delete: owner (authz/model.fga) -- volontairement plus étroit que
    can_manage_members/can_set_cover/can_change_visibility (owner ou admin) :
    un admin gère la playlist au quotidien, mais ne peut pas la faire
    disparaître. L'admin, ici, est l'ancien propriétaire : donner la
    playlist est la seule façon d'en devenir un."""
    admin = make_user()
    new_owner = make_user()
    _, body = create_playlist(admin)
    playlist_id = int(body["playlist"]["id"])
    invite_to_playlist(playlist_id, admin, new_owner)
    status, _ = eventually(
        lambda: transfer_ownership(playlist_id, new_owner, admin),
        lambda status, _: status == 200,
    )
    assert status == 200

    status, _ = delete_playlist(playlist_id, admin)
    assert status == 403


def test_non_owner_cannot_delete(make_user, create_playlist, delete_playlist):
    owner = make_user()
    stranger = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])

    status, _ = delete_playlist(playlist_id, stranger)
    assert status == 403


def test_deleting_twice_is_denied_the_second_time(make_user, create_playlist, delete_playlist):
    """La deuxième suppression ne peut plus atteindre le handler du tout :
    deleted_at IS NULL fait déjà échouer la résolution de l'UUID public au
    niveau de l'intercepteur -- refus de permission, pas d'erreur "déjà
    supprimée" distincte."""
    owner = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])
    assert delete_playlist(playlist_id, owner)[0] == 200

    status, _ = delete_playlist(playlist_id, owner)
    assert status == 403
