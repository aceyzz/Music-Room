"""BlockUser / UnblockUser / ListBlockedUsers : bloquer quelqu'un rompt
l'amitié existante et annule toute demande en attente entre les deux
comptes (internal/user/service.go:BlockUser), et empêche l'envoi de
nouvelles demandes d'ami tant que le blocage tient."""


def test_block_dissolves_existing_friendship(
    api, make_user, make_friendship, block_user, public_id_of, auth_headers
):
    alice = make_user()
    bob = make_user()
    make_friendship(alice, bob)
    alice_friends = f"/v1/users/{public_id_of(alice)}/friends"
    assert {int(f["id"]) for f in api.get(alice_friends, headers=auth_headers(alice))[1]["friends"]} == {
        bob
    }

    status, _ = block_user(bob, alice)
    assert status == 200

    # Rupture de la ligne friendships elle-même : effet SQL synchrone du
    # handler, pas une tuple OpenFGA -- immédiat, pas besoin d'eventually().
    status, body = api.get(alice_friends, headers=auth_headers(alice))
    assert status == 200
    assert body["friends"] == []


def test_block_cancels_pending_friend_request(
    send_friend_request, block_user, list_friend_requests, make_user
):
    alice = make_user()
    bob = make_user()
    send_friend_request(alice, bob)

    status, _ = block_user(bob, alice)
    assert status == 200

    status, body = list_friend_requests(bob, direction="incoming")
    assert status == 200
    assert body["requests"] == []


def test_blocked_user_cannot_send_a_friend_request(send_friend_request, block_user, make_user, eventually):
    """can_send_friend_request dépend de la tuple `blocked`, écrite par
    BlockUser via l'outbox (asynchrone, voir tests/conftest.py:eventually) --
    contrairement à la rupture de friendship (SQL direct), il faut donc
    laisser une marge après block_user() avant que le refus soit garanti."""
    alice = make_user()
    bob = make_user()
    block_user(bob, alice)

    status, _ = eventually(
        lambda: send_friend_request(alice, bob), lambda status, _: status == 403
    )
    assert status == 403


def test_blocking_is_idempotent(block_user, make_user):
    alice = make_user()
    bob = make_user()
    assert block_user(alice, bob)[0] == 200
    status, _ = block_user(alice, bob)
    assert status == 200


def test_cannot_block_yourself(block_user, make_user):
    user = make_user()
    status, _ = block_user(user, user)
    assert status == 400


def test_unblock_allows_a_new_friend_request(
    block_user, unblock_user, send_friend_request, make_user, eventually
):
    alice = make_user()
    bob = make_user()
    block_user(bob, alice)
    status, _ = eventually(
        lambda: send_friend_request(alice, bob), lambda status, _: status == 403
    )
    assert status == 403

    status, _ = unblock_user(bob, alice)
    assert status == 200

    # Suppression de la tuple `blocked`, elle aussi via l'outbox : même
    # raisonnement que le blocage lui-même.
    status, _ = eventually(
        lambda: send_friend_request(alice, bob), lambda status, _: status == 200
    )
    assert status == 200


def test_list_blocked_users(block_user, list_blocked_users, make_user):
    alice = make_user()
    bob = make_user()
    carol = make_user()
    block_user(alice, bob)
    block_user(alice, carol)

    status, body = list_blocked_users(alice)
    assert status == 200
    assert {int(u["id"]) for u in body["blockedUsers"]} == {bob, carol}

    # bob et carol n'ont bloqué personne : le blocage n'est pas symétrique.
    status, body = list_blocked_users(bob)
    assert status == 200
    assert body["blockedUsers"] == []
