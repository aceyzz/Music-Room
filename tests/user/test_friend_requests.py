"""V.1 réseau social : envoyer / accepter / refuser une demande d'ami
(friend_requests -> friendships, docs/data-model.md §7)."""

import uuid


def test_send_then_accept_creates_a_friendship(
    send_friend_request, accept_friend_request, list_friend_requests, get_user, update_profile, make_user
):
    """Chemin nominal complet : la demande apparaît dans les entrantes de
    l'addressee, l'acceptation crée réellement la ligne friendships (visible
    ensuite via GetUser en scope friends, pas seulement via GetFriends)."""
    alice = make_user()
    bob = make_user()
    update_profile(alice, first_name="Alice")

    status, body = send_friend_request(alice, bob, message="salut !")
    assert status == 200
    request_id = int(body["request"]["id"])
    assert body["request"]["status"] == "pending"

    status, body = list_friend_requests(bob, direction="incoming")
    assert status == 200
    assert [int(r["id"]) for r in body["requests"]] == [request_id]

    # Avant acceptation, bob ne voit pas encore les champs "friends" d'alice.
    assert get_user(alice, viewer_id=bob)[1]["user"]["firstName"] == ""

    status, body = accept_friend_request(request_id, bob)
    assert status == 200
    assert int(body["friend"]["id"]) == alice

    status, body = get_user(alice, viewer_id=bob)
    assert status == 200
    assert body["user"]["firstName"] == "Alice"


def test_cannot_send_a_request_to_yourself(send_friend_request, make_user):
    user = make_user()
    status, _ = send_friend_request(user, user)
    assert status == 400


def test_request_to_a_nonexistent_user_is_denied(api, make_user, public_id_of, auth_headers):
    """La Requirement d'addressee_public_id (policy.go) ne porte pas
    NotFound:true (contrairement à BlockUser) : un public_id qui ne résout
    aucune tuple `anyone` échoue le Check can_send_friend_request comme
    n'importe quel refus de permission, donc 403 et non 404 -- l'intercepteur
    ne peut pas distinguer "n'existe pas" de "existe mais bloqué" ici. La
    fixture send_friend_request ne peut pas construire ce cas (elle résout
    addressee_id via public_id_of, qui suppose un make_user existant), d'où
    l'appel direct avec un UUID syntaxiquement valide mais inconnu."""
    user = make_user()
    status, _ = api.post(
        f"/v1/users/{public_id_of(user)}/friend-requests",
        json={"addressee_public_id": str(uuid.uuid4())},
        headers=auth_headers(user),
    )
    assert status == 403


def test_duplicate_pending_request_conflicts(send_friend_request, make_user):
    """Renvoyer une demande dans le même sens pendant que la première est
    encore pending doit être refusé (409), pas créer une deuxième ligne."""
    alice = make_user()
    bob = make_user()
    assert send_friend_request(alice, bob)[0] == 200

    status, _ = send_friend_request(alice, bob)
    assert status == 409


def test_crossed_pending_request_conflicts(send_friend_request, make_user):
    """L'index unique friend_requests_one_open_per_pair normalise la paire :
    alice->bob pending doit aussi bloquer bob->alice, pas seulement un
    renvoi dans le même sens."""
    alice = make_user()
    bob = make_user()
    assert send_friend_request(alice, bob)[0] == 200

    status, _ = send_friend_request(bob, alice)
    assert status == 409


def test_request_between_already_friends_conflicts(send_friend_request, make_user, make_friendship):
    alice = make_user()
    bob = make_user()
    make_friendship(alice, bob)

    status, _ = send_friend_request(alice, bob)
    assert status == 409


def test_decline_does_not_create_a_friendship(
    send_friend_request, decline_friend_request, get_user, make_user
):
    alice = make_user()
    bob = make_user()
    _, body = send_friend_request(alice, bob)
    request_id = int(body["request"]["id"])

    status, _ = decline_friend_request(request_id, bob)
    assert status == 200

    # Toujours strangers : bob ne voit pas les champs "friends" d'alice.
    status, body = get_user(alice, viewer_id=bob)
    assert status == 200
    assert body["user"]["firstNameVisibility"] == "friends"


def test_accept_by_someone_other_than_the_addressee_is_not_found(
    send_friend_request, accept_friend_request, make_user
):
    """Seul l'addressee peut accepter -- même le requester lui-même ne peut
    pas accepter sa propre demande à sa place."""
    alice = make_user()
    bob = make_user()
    _, body = send_friend_request(alice, bob)
    request_id = int(body["request"]["id"])

    status, _ = accept_friend_request(request_id, alice)
    assert status == 404


def test_accepting_twice_is_not_found_the_second_time(
    send_friend_request, accept_friend_request, make_user
):
    alice = make_user()
    bob = make_user()
    _, body = send_friend_request(alice, bob)
    request_id = int(body["request"]["id"])
    assert accept_friend_request(request_id, bob)[0] == 200

    status, _ = accept_friend_request(request_id, bob)
    assert status == 404


def test_list_friend_requests_incoming_vs_outgoing(send_friend_request, list_friend_requests, make_user):
    alice = make_user()
    bob = make_user()
    send_friend_request(alice, bob)

    status, body = list_friend_requests(alice, direction="outgoing")
    assert status == 200
    assert len(body["requests"]) == 1

    status, body = list_friend_requests(alice, direction="incoming")
    assert status == 200
    assert body["requests"] == []

    status, body = list_friend_requests(bob, direction="incoming")
    assert status == 200
    assert len(body["requests"]) == 1


def test_too_many_friend_requests_in_a_row_are_refused(send_friend_request, make_user):
    """Limite par utilisateur sur les routes sociales (interceptor/throttle.go) :
    10 demandes d'affilée, puis une toutes les 6 s. La 11e immédiate est
    refusée (RESOURCE_EXHAUSTED -> 429), un autre utilisateur n'est pas touché."""
    spammer = make_user()
    for _ in range(10):
        status, body = send_friend_request(spammer, make_user())
        assert status == 200, body

    status, body = send_friend_request(spammer, make_user())
    assert status == 429, body

    status, body = send_friend_request(make_user(), make_user())
    assert status == 200, body
