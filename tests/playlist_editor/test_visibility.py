"""V.2.3 : une playlist publique se trouve par tout le monde ; une privée
seulement par son propriétaire ou un membre invité via InviteToPlaylist."""


def test_private_playlist_is_hidden_from_non_member(api, make_user, create_playlist, get_playlist):
    """Une playlist privée doit être invisible pour quiconque n'y a pas été
    invité -- 404, pas 403, pour ne pas révéler son existence à un
    outsider -- alors que le propriétaire y accède toujours normalement."""
    owner = make_user()
    outsider = make_user()
    _, body = create_playlist(owner, visibility="private")
    playlist_id = int(body["playlist"]["id"])

    status, _ = get_playlist(playlist_id, outsider)
    assert status == 404

    status, _ = get_playlist(playlist_id, owner)
    assert status == 200


def test_invite_by_non_owner_is_forbidden(make_user, create_playlist, invite_to_playlist):
    """Seul le propriétaire peut inviter quelqu'un à une playlist privée --
    un tiers ne peut pas élargir la liste des membres à sa place, même s'il
    connaît le playlist_id."""
    owner = make_user()
    someone_else = make_user()
    target = make_user()
    _, body = create_playlist(owner, visibility="private")
    playlist_id = int(body["playlist"]["id"])

    status, _ = invite_to_playlist(playlist_id, someone_else, target)
    assert status == 403


def test_invite_makes_private_playlist_visible_to_invitee(
    make_user, create_playlist, get_playlist, invite_to_playlist, eventually
):
    """Chemin nominal : avant l'invitation, l'ami ne voit rien (comme dans
    test_private_playlist_is_hidden_from_non_member) ; après, il y accède
    normalement -- InviteToPlaylist doit réellement débloquer l'accès, pas
    juste renvoyer un succès sans effet."""
    owner = make_user()
    friend = make_user()
    _, body = create_playlist(owner, visibility="private")
    playlist_id = int(body["playlist"]["id"])

    status, _ = get_playlist(playlist_id, friend)
    assert status == 404

    status, _ = invite_to_playlist(playlist_id, owner, friend)
    assert status == 200

    # La tuple viewer écrite par l'invitation passe par l'outbox (asynchrone,
    # voir tests/conftest.py:eventually), donc l'effet n'est pas forcément
    # déjà visible à la requête suivante.
    status, _ = eventually(
        lambda: get_playlist(playlist_id, friend), lambda status, _: status == 200
    )
    assert status == 200
