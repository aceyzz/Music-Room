"""GetFriends : la liste d'amis d'un utilisateur, identifié par public_id
dans le chemin (self-only, on ne peut lister que ses propres amis)."""


def test_get_friends_lists_all_friends(api, make_user, make_friendship, public_id_of, auth_headers):
    alice = make_user()
    bob = make_user()
    carol = make_user()
    make_friendship(alice, bob)
    make_friendship(alice, carol)

    status, body = api.get(f"/v1/users/{public_id_of(alice)}/friends", headers=auth_headers(alice))
    assert status == 200
    assert {int(f["id"]) for f in body["friends"]} == {bob, carol}


def test_get_friends_is_empty_for_a_user_with_no_friends(api, make_user, public_id_of, auth_headers):
    user = make_user()
    status, body = api.get(f"/v1/users/{public_id_of(user)}/friends", headers=auth_headers(user))
    assert status == 200
    assert body["friends"] == []
