"""SearchPublicPlaylists : le filtre Public de l'onglet Playlists -- toutes les
playlists publiques dont le nom contient la recherche (sans tenir compte de
la casse), les plus récentes d'abord, page par page. Jamais une privée, rien
d'un propriétaire bloqué."""

import uuid

import pytest


@pytest.fixture
def search_public(api, auth_headers, public_id_of):
    def _search(viewer_id, query="", page_size=0, page_token="", my_taste=False):
        params = f"query={query}&page_size={page_size}&page_token={page_token}"
        if my_taste:
            params += "&my_taste=true"
        return api.get(
            f"/v1/users/{public_id_of(viewer_id)}/playlists/public?{params}",
            headers=auth_headers(viewer_id),
        )

    return _search


def _names(body):
    return [p["name"] for p in body["playlists"]]


def test_finds_public_playlists_by_name_never_private_ones(make_user, create_playlist, search_public):
    me = make_user()
    stranger = make_user()
    tag = uuid.uuid4().hex[:8]
    create_playlist(stranger, name=f"Jazz {tag} public", visibility="public")
    create_playlist(stranger, name=f"Jazz {tag} private", visibility="private")
    create_playlist(stranger, name=f"Rock {tag}", visibility="public")

    status, body = search_public(me, query=f"JAZZ {tag}")
    assert status == 200
    assert _names(body) == [f"Jazz {tag} public"]
    assert body["playlists"][0]["relation"] == "public"


def test_pages_newest_first(make_user, create_playlist, search_public):
    me = make_user()
    owner = make_user()
    tag = uuid.uuid4().hex[:8]
    for i in range(3):
        create_playlist(owner, name=f"Paged {tag} {i}", visibility="public")

    status, first = search_public(me, query=tag, page_size=2)
    assert status == 200
    assert _names(first) == [f"Paged {tag} 2", f"Paged {tag} 1"]
    assert first["nextPageToken"]

    status, second = search_public(me, query=tag, page_size=2, page_token=first["nextPageToken"])
    assert status == 200
    assert _names(second) == [f"Paged {tag} 0"]
    assert second.get("nextPageToken", "") == ""


def test_a_blocked_owner_is_left_out(make_user, create_playlist, search_public, db_conn):
    me = make_user()
    owner = make_user()
    tag = uuid.uuid4().hex[:8]
    create_playlist(owner, name=f"Blocked {tag}", visibility="public")
    with db_conn.cursor() as cur:
        cur.execute("INSERT INTO user_blocks (blocker_id, blocked_id) VALUES (%s, %s)", (me, owner))

    status, body = search_public(me, query=tag)
    assert status == 200
    assert _names(body) == []


def test_a_bad_page_token_is_refused(make_user, search_public):
    status, _ = search_public(make_user(), page_token="nope")
    assert status == 400


@pytest.fixture
def likes(api, auth_headers, public_id_of):
    """Sets a user's music preferences to [genres] (Deezer ids), and who may
    see them."""
    def _likes(user_id, *genres, visibility="public"):
        status, _ = api.put(
            f"/v1/users/{public_id_of(user_id)}/music-preferences",
            json={"preferences": [
                {"deezer_genre_id": g, "genre_name": f"genre {g}", "weight": 3} for g in genres
            ]},
            headers=auth_headers(user_id),
        )
        assert status == 200
        status, _ = api.patch(
            f"/v1/users/{public_id_of(user_id)}/profile",
            json={"preferences_visibility": visibility},
            headers=auth_headers(user_id),
        )
        assert status == 200

    return _likes


JAZZ, ROCK, POP = 129, 152, 132


def test_my_taste_keeps_the_playlists_of_people_who_like_a_genre_i_like(
    make_user, create_playlist, search_public, likes
):
    me = make_user()
    jazz_fan = make_user()
    rock_fan = make_user()
    tag = uuid.uuid4().hex[:8]
    likes(me, JAZZ, POP)
    likes(jazz_fan, JAZZ)
    likes(rock_fan, ROCK)
    create_playlist(jazz_fan, name=f"Taste {tag} jazz", visibility="public")
    create_playlist(rock_fan, name=f"Taste {tag} rock", visibility="public")

    status, body = search_public(me, query=tag, my_taste=True)
    assert status == 200
    assert _names(body) == [f"Taste {tag} jazz"]

    # Off, both show.
    status, body = search_public(me, query=tag)
    assert sorted(_names(body)) == [f"Taste {tag} jazz", f"Taste {tag} rock"]


def test_my_taste_never_reveals_tastes_kept_private(make_user, create_playlist, search_public, likes):
    """A jazz fan who shows their music preferences to friends only does not
    show up for a stranger who likes jazz: the filter would tell them."""
    me = make_user()
    hidden_fan = make_user()
    tag = uuid.uuid4().hex[:8]
    likes(me, JAZZ)
    likes(hidden_fan, JAZZ, visibility="friends")
    create_playlist(hidden_fan, name=f"Hidden {tag}", visibility="public")

    status, body = search_public(me, query=tag, my_taste=True)
    assert status == 200
    assert _names(body) == []
