"""TransferPlaylistOwnership (docs/todo.md §2) : le propriétaire passe la
main à un membre existant. L'ancien propriétaire devient admin -- il garde
la gestion au quotidien, mais perd can_delete/can_transfer_ownership."""


def test_owner_transfers_to_an_existing_member(
    make_user, create_playlist, invite_to_playlist, transfer_ownership, delete_playlist, set_visibility, eventually
):
    owner = make_user()
    member = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])
    invite_to_playlist(playlist_id, owner, member)

    status, body = eventually(
        lambda: transfer_ownership(playlist_id, member, owner),
        lambda status, _: status in (200, 404),  # 404 tant que l'invitation n'a pas pris.
    )
    assert status == 200
    assert int(body["playlist"]["ownerId"]) == member

    # L'ancien propriétaire est devenu admin : peut toujours gérer...
    status, _ = set_visibility(playlist_id, "private", owner)
    assert status == 200
    # ...mais plus supprimer (can_delete: owner uniquement).
    status, _ = delete_playlist(playlist_id, owner)
    assert status == 403

    # Le nouveau propriétaire, lui, le peut.
    status, _ = delete_playlist(playlist_id, member)
    assert status == 200


def test_cannot_transfer_to_a_non_member(make_user, create_playlist, transfer_ownership):
    """new_owner_user_id doit déjà avoir une ligne playlist_members : pas de
    transfert surprise vers quelqu'un qui n'a jamais été invité."""
    owner = make_user()
    outsider = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])

    status, _ = transfer_ownership(playlist_id, outsider, owner)
    assert status == 404


def test_non_owner_cannot_transfer(
    make_user, create_playlist, invite_to_playlist, transfer_ownership, eventually
):
    owner = make_user()
    member = make_user()
    someone_else = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])
    invite_to_playlist(playlist_id, owner, member)

    status, _ = eventually(
        lambda: transfer_ownership(playlist_id, member, someone_else),
        lambda status, _: status != 404,  # laisse le temps à l'invitation, sans le confondre avec le vrai refus.
    )
    assert status == 403


def test_cannot_transfer_to_yourself(make_user, create_playlist, transfer_ownership):
    owner = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])

    status, _ = transfer_ownership(playlist_id, owner, owner)
    assert status == 400
