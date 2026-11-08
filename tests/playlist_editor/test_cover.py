"""SetPlaylistCover / DeletePlaylistCover : même mécanique que l'avatar
(UserService, tests/user/test_avatar.py) -- upload, resize carré via
image-service, remplacement propre -- mais réservée au propriétaire de la
playlist."""

import uuid


def test_owner_can_set_the_cover_and_it_is_served(
    create_playlist, set_playlist_cover, fetch_media, make_user
):
    owner = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])
    assert body["playlist"]["coverStorageKey"] == ""

    status, body = set_playlist_cover(playlist_id, owner)
    assert status == 200
    storage_key = body["playlist"]["coverStorageKey"]
    assert storage_key

    status, content = fetch_media(storage_key)
    assert status == 200
    assert content[:8] == b"\x89PNG\r\n\x1a\n"


def test_non_owner_cannot_set_the_cover(create_playlist, set_playlist_cover, make_user):
    owner = make_user()
    someone_else = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])

    status, _ = set_playlist_cover(playlist_id, someone_else)
    assert status == 403


def test_set_cover_rejects_an_unsupported_content_type(create_playlist, set_playlist_cover, make_user):
    owner = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])

    status, _ = set_playlist_cover(playlist_id, owner, content_type="application/pdf")
    assert status == 400


def test_set_cover_rejects_bytes_that_are_not_an_image(create_playlist, set_playlist_cover, make_user):
    owner = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])

    status, _ = set_playlist_cover(playlist_id, owner, image_base64="aGVsbG8=")
    assert status == 400


def test_set_cover_of_an_unknown_playlist_is_denied(
    api, make_user, auth_headers, tiny_png_base64
):
    """set_playlist_cover (la fixture) résout playlist_id via
    playlist_public_id_of, qui suppose une playlist réellement créée par
    create_playlist -- pour un id qui n'a jamais existé, un UUID
    syntaxiquement valide passé directement fait l'affaire. SetPlaylistCover
    ne porte pas NotFound:true (policy.go, comme RemoveSongFromPlaylist) :
    403, pas 404 -- voir test_not_found.py."""
    owner = make_user()
    status, _ = api.post(
        f"/v1/playlists/{uuid.uuid4()}/cover",
        json={"image_data": tiny_png_base64, "content_type": "image/png"},
        headers=auth_headers(owner),
    )
    assert status == 403


def test_setting_the_cover_again_replaces_the_previous_one(
    create_playlist, set_playlist_cover, fetch_media, make_user
):
    owner = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])

    _, first = set_playlist_cover(playlist_id, owner)
    first_key = first["playlist"]["coverStorageKey"]
    assert fetch_media(first_key)[0] == 200

    _, second = set_playlist_cover(playlist_id, owner)
    second_key = second["playlist"]["coverStorageKey"]
    assert second_key != first_key

    assert fetch_media(first_key)[0] == 404
    assert fetch_media(second_key)[0] == 200


def test_owner_can_delete_the_cover(
    create_playlist, set_playlist_cover, delete_playlist_cover, fetch_media, make_user
):
    owner = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])
    _, body = set_playlist_cover(playlist_id, owner)
    storage_key = body["playlist"]["coverStorageKey"]

    status, body = delete_playlist_cover(playlist_id, owner)
    assert status == 200
    assert body["playlist"]["coverStorageKey"] == ""
    assert fetch_media(storage_key)[0] == 404


def test_non_owner_cannot_delete_the_cover(create_playlist, set_playlist_cover, delete_playlist_cover, make_user):
    owner = make_user()
    someone_else = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])
    set_playlist_cover(playlist_id, owner)

    status, _ = delete_playlist_cover(playlist_id, someone_else)
    assert status == 403


def test_delete_cover_with_none_set_is_a_silent_success(create_playlist, delete_playlist_cover, make_user):
    owner = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])

    status, _ = delete_playlist_cover(playlist_id, owner)
    assert status == 200
