"""RenamePlaylist : playlist#can_rename (authz/model.fga) est owner OU admin,
comme can_change_visibility/can_change_license -- pas owner-only comme
can_delete/can_transfer_ownership. Trou découvert en auditant playlist_ops :
l'enum Postgres playlist_op_type avait 'rename' depuis le début (00011_playlists)
et docs/permissions.md documentait déjà la règle, mais aucune RPC n'existait."""

import json


def test_owner_can_rename(make_user, create_playlist, rename_playlist):
    owner = make_user()
    _, body = create_playlist(owner, name="Old Name")
    playlist_id = int(body["playlist"]["id"])

    status, body = rename_playlist(playlist_id, "New Name", owner)
    assert status == 200
    assert body["playlist"]["name"] == "New Name"


def test_admin_can_rename(
    make_user, create_playlist, invite_to_playlist, transfer_ownership, rename_playlist, eventually
):
    """L'admin est l'ancien propriétaire : donner la playlist est la seule
    façon d'en devenir un."""
    admin = make_user()
    new_owner = make_user()
    _, body = create_playlist(admin, name="Old Name")
    playlist_id = int(body["playlist"]["id"])
    invite_to_playlist(playlist_id, admin, new_owner)
    status, _ = eventually(
        lambda: transfer_ownership(playlist_id, new_owner, admin),
        lambda status, _: status == 200,
    )
    assert status == 200

    status, body = eventually(
        lambda: rename_playlist(playlist_id, "New Name", admin),
        lambda status, _: status == 200,
    )
    assert status == 200
    assert body["playlist"]["name"] == "New Name"


def test_editor_cannot_rename(make_user, create_playlist, invite_to_playlist, rename_playlist, eventually):
    """can_rename n'inclut pas editor/viewer, contrairement à can_edit_songs
    (qui lui est ouvert à tout membre via can_view and open_edit)."""
    owner = make_user()
    editor = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])
    invite_to_playlist(playlist_id, owner, editor)  # default role: editor.

    status, _ = eventually(
        lambda: rename_playlist(playlist_id, "New Name", editor),
        lambda status, _: status != 404,  # laisse le temps à l'invitation, sans le confondre avec 403.
    )
    assert status == 403


def test_non_member_cannot_rename(make_user, create_playlist, rename_playlist):
    owner = make_user()
    outsider = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])

    status, _ = rename_playlist(playlist_id, "New Name", outsider)
    assert status == 403


def test_journals_the_rename(make_user, create_playlist, rename_playlist, list_ops):
    owner = make_user()
    _, body = create_playlist(owner, name="Old Name")
    playlist_id = int(body["playlist"]["id"])

    status, _ = rename_playlist(playlist_id, "New Name", owner)
    assert status == 200

    status, body = list_ops(playlist_id, owner, since_revision=0)
    assert status == 200
    assert len(body["ops"]) == 1
    op = body["ops"][0]
    assert int(op["revision"]) == 1
    assert op["opType"] == "rename"
    assert json.loads(op["payload"]) == {"name": "New Name"}
    assert int(op["actorId"]) == 0  # pas de CallerPublicIDField, même raisonnement que visibility/license.
