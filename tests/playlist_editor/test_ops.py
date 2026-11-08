"""ListPlaylistOpsSince (docs/todo.md §2) : rejoue le journal playlist_ops
pour qu'un client reconnecté rattrape les mutations manquées plutôt que de
tout recharger. Même garde que GetPlaylist (playlist#can_view)."""

import json


def test_lists_ops_after_the_given_revision(make_user, make_song, create_playlist, add_song, list_ops):
    owner = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])

    status, body = list_ops(playlist_id, owner)
    assert status == 200
    assert body["ops"] == []

    status, body = add_song(playlist_id, make_song(), owner)
    assert status == 200
    playlist_song_id = int(body["songs"][0]["id"])

    status, body = list_ops(playlist_id, owner, since_revision=0)
    assert status == 200
    assert len(body["ops"]) == 1
    op = body["ops"][0]
    assert int(op["revision"]) == 1
    assert op["opType"] == "add_song"
    assert json.loads(op["payload"])["playlist_song_id"] == playlist_song_id

    # since_revision exclut la revision donnée : rien de plus récent qu'elle-même.
    status, body = list_ops(playlist_id, owner, since_revision=1)
    assert status == 200
    assert body["ops"] == []


def test_private_playlist_ops_are_hidden_from_non_member(
    make_user, make_song, create_playlist, add_song, list_ops
):
    owner = make_user()
    outsider = make_user()
    _, body = create_playlist(owner, visibility="private")
    playlist_id = int(body["playlist"]["id"])
    add_song(playlist_id, make_song(), owner)

    status, _ = list_ops(playlist_id, outsider)
    assert status == 404


def test_journals_visibility_and_license_changes(
    make_user, create_playlist, set_visibility, set_edit_license, list_ops
):
    """visibility_change/license_change existaient dans l'enum playlist_op_type
    depuis le début (00011_playlists) mais n'étaient jamais écrits : un client
    reconnecté ratait silencieusement ces deux mutations. Ni SetPlaylistVisibility
    ni SetPlaylistEditLicense n'ont de CallerPublicIDField (policy.go) -- l'acteur
    est donc inconnu de l'intercepteur, et actor_id reste 0 (non "non enregistré"
    -- PlaylistOpDTO.actor_id documente déjà ce 0 comme un état légitime)."""
    owner = make_user()
    _, body = create_playlist(owner, visibility="public")
    playlist_id = int(body["playlist"]["id"])

    status, _ = set_visibility(playlist_id, "private", owner)
    assert status == 200
    status, _ = set_edit_license(playlist_id, "invited_only", owner)
    assert status == 200

    status, body = list_ops(playlist_id, owner, since_revision=0)
    assert status == 200
    assert len(body["ops"]) == 2

    visibility_op, license_op = body["ops"]
    assert int(visibility_op["revision"]) == 1
    assert visibility_op["opType"] == "visibility_change"
    assert json.loads(visibility_op["payload"]) == {"visibility": "private"}
    assert int(visibility_op["actorId"]) == 0

    assert int(license_op["revision"]) == 2
    assert license_op["opType"] == "license_change"
    assert json.loads(license_op["payload"]) == {"edit_license": "invited_only"}


def test_journals_ownership_transfer(
    make_user, create_playlist, invite_to_playlist, transfer_ownership, list_ops, eventually
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

    status, body = list_ops(playlist_id, member, since_revision=0)
    assert status == 200
    assert len(body["ops"]) == 1
    op = body["ops"][0]
    assert int(op["revision"]) == 1
    assert op["opType"] == "ownership_transfer"
    assert int(op["actorId"]) == owner  # TransferPlaylistOwnership a un CallerPublicIDField, lui.
    payload = json.loads(op["payload"])
    assert int(payload["new_owner_user_id"]) == member
    assert int(payload["previous_owner_user_id"]) == owner
