"""ListLibraryPlaylists : la bibliothèque de l'onglet Playlists -- les
playlists de l'appelant, celles dont il est membre, et les publiques de ses
amis. Pas les publiques d'inconnus (c'est le filtre Public, une autre RPC),
pas les privées d'un ami dont il n'est pas membre, rien d'un propriétaire
bloqué."""

import pytest


@pytest.fixture
def list_library(api, auth_headers, public_id_of):
    def _list(viewer_id):
        return api.get(f"/v1/users/{public_id_of(viewer_id)}/playlists", headers=auth_headers(viewer_id))

    return _list


def _by_id(body):
    return {p["publicId"]: p for p in body["playlists"]}


def test_library_holds_mine_shared_and_friends_public_ones(
    make_user, make_friendship, create_playlist, invite_to_playlist, list_library, eventually,
):
    me = make_user()
    friend = make_user()
    stranger = make_user()
    make_friendship(me, friend)

    _, mine = create_playlist(me, visibility="private")
    _, shared = create_playlist(stranger, visibility="private")
    invite_to_playlist(int(shared["playlist"]["id"]), stranger, me)
    _, friends_public = create_playlist(friend, visibility="public")
    _, friends_private = create_playlist(friend, visibility="private")
    _, strangers_public = create_playlist(stranger, visibility="public")

    expected = {
        mine["playlist"]["publicId"]: "mine",
        shared["playlist"]["publicId"]: "shared",
        friends_public["playlist"]["publicId"]: "friend",
    }
    status, body = eventually(
        lambda: list_library(me),
        lambda status, body: status == 200 and set(expected) <= set(_by_id(body)),
    )
    assert status == 200
    library = _by_id(body)
    assert {pid: library[pid]["relation"] for pid in expected} == expected
    assert library[friends_public["playlist"]["publicId"]]["ownerIsFriend"] is True
    assert friends_private["playlist"]["publicId"] not in library
    assert strangers_public["playlist"]["publicId"] not in library


def test_a_blocked_owner_is_left_out(
    make_user, make_friendship, create_playlist, list_library, eventually, db_conn,
):
    me = make_user()
    friend = make_user()
    make_friendship(me, friend)
    _, playlist = create_playlist(friend, visibility="public")
    playlist_id = playlist["playlist"]["publicId"]
    eventually(
        lambda: list_library(me),
        lambda status, body: status == 200 and playlist_id in _by_id(body),
    )

    with db_conn.cursor() as cur:
        cur.execute("INSERT INTO user_blocks (blocker_id, blocked_id) VALUES (%s, %s)", (friend, me))

    status, body = list_library(me)
    assert status == 200
    assert playlist_id not in _by_id(body)


def test_cannot_list_someone_elses_library(make_user, api, auth_headers, public_id_of):
    me = make_user()
    other = make_user()
    status, _ = api.get(f"/v1/users/{public_id_of(other)}/playlists", headers=auth_headers(me))
    assert status == 403
