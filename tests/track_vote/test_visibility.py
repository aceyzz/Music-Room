"""V.2.1 : un événement public se trouve par tout le monde ; un événement
privé seulement par son hôte ou un membre invité via InviteToEvent."""

import uuid


def test_private_event_is_hidden_from_non_member(
    make_user, make_song, create_event, suggest, get_event, get_queue, get_playback, list_members
):
    """Un event privé doit être invisible sur TOUS les points d'entrée qui
    en dépendent (lecture directe, file, radio, liste des membres) -- pas
    seulement sur l'un d'eux. La réponse est un 404 générique plutôt qu'un
    403 sur ces quatre routes : ça évite de révéler à un outsider que
    l'event existe même si son contenu reste caché.

    SuggestSong fait exception : sa Requirement (policy.go) ne porte pas
    NotFound:true, contrairement aux quatre lectures ci-dessus -- refuser
    d'écrire dans un event qu'on ne peut pas voir remonte donc en 403, pas
    en 404 (même raisonnement que InviteToEvent vers un utilisateur
    inconnu, voir test_invite_a_nonexistent_user_is_denied)."""
    host = make_user()
    outsider = make_user()
    _, body = create_event(host, visibility="private")
    event_id = int(body["event"]["id"])

    assert get_event(event_id, outsider)[0] == 404
    assert get_queue(event_id, outsider)[0] == 404
    assert get_playback(event_id, outsider)[0] == 404
    assert list_members(event_id, outsider)[0] == 404
    status, _ = suggest(event_id, outsider, make_song())
    assert status == 403

    # Host always sees their own event.
    assert get_event(event_id, host)[0] == 200


def test_invite_by_non_host_is_forbidden(make_user, create_event, invite_to_event):
    """Seul l'hôte peut inviter quelqu'un à un event privé -- un autre
    utilisateur (même s'il existe, même si la cible existe) ne peut pas
    élargir la liste des invités à sa place."""
    host = make_user()
    someone_else = make_user()
    target = make_user()
    _, body = create_event(host, visibility="private")
    event_id = int(body["event"]["id"])

    status, _ = invite_to_event(event_id, someone_else, target)
    assert status == 403


def test_invite_makes_private_event_visible_and_listed(
    make_user, create_event, get_event, invite_to_event, list_members, eventually
):
    """Le chemin nominal de la visibilité privée : avant l'invitation, un
    utilisateur ne voit rien (comme dans test_private_event_is_hidden_...) ;
    après, il voit l'event ET apparaît dans la liste des membres aux côtés de
    l'hôte (qui y est depuis la création, avec le rôle "owner")."""
    host = make_user()
    friend = make_user()
    _, body = create_event(host, visibility="private")
    event_id = int(body["event"]["id"])

    assert get_event(event_id, friend)[0] == 404

    status, _ = invite_to_event(event_id, host, friend)
    assert status == 200

    # La tuple viewer écrite par l'invitation passe par l'outbox (asynchrone,
    # voir tests/conftest.py:eventually).
    status, _ = eventually(
        lambda: get_event(event_id, friend), lambda status, _: status == 200
    )
    assert status == 200

    status, body = list_members(event_id, friend)
    assert status == 200
    assert {int(m["userId"]) for m in body["members"]} == {host, friend}


def test_invite_a_nonexistent_user_is_denied(make_user, create_event, invite_to_event, api, auth_headers):
    """InviteToEvent vérifie que l'invité existe -- mais sa Requirement
    (policy.go) ne porte pas NotFound:true, contrairement à GetMusicEvent :
    un public_id qui ne résout aucune tuple `anyone` échoue le Check
    can_receive_invitation comme n'importe quel refus (403), pas 404 --
    l'intercepteur ne peut pas distinguer "n'existe pas" de "existe mais
    bloqué" ici (même raisonnement que UserService.SendFriendRequest,
    tests/user/test_friend_requests.py)."""
    host = make_user()
    _, body = create_event(host, visibility="private")
    event_id = int(body["event"]["id"])

    status, _ = api.post(
        f"/v1/events/{body['event']['publicId']}/members",
        json={"invitee_user_public_id": str(uuid.uuid4())},
        headers=auth_headers(host),
    )
    assert status == 403


def test_the_host_makes_a_public_event_private_and_back(
    make_user, create_event, get_event, invite_to_event, set_visibility, eventually
):
    """V.2.1 visibility, changed after creation: made private, the event
    disappears for a stranger (404, as if it never existed) and stays open to
    an invited guest; made public again, the stranger finds it again."""
    host = make_user()
    guest = make_user()
    stranger = make_user()
    _, body = create_event(host)  # public by default
    event_id = int(body["event"]["id"])
    invite_to_event(event_id, host, guest)
    assert get_event(event_id, stranger)[0] == 200

    status, body = set_visibility(event_id, host, "private")
    assert status == 200
    assert body["event"]["visibility"] == "private"
    # The tuple goes through the outbox (tests/conftest.py:eventually).
    eventually(lambda: get_event(event_id, stranger), lambda status, _: status == 404)
    assert get_event(event_id, guest)[0] == 200

    assert set_visibility(event_id, host, "public")[0] == 200
    eventually(lambda: get_event(event_id, stranger), lambda status, _: status == 200)


def test_only_the_host_changes_visibility(make_user, create_event, set_visibility):
    host = make_user()
    other = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])

    assert set_visibility(event_id, other, "private")[0] == 403
    assert set_visibility(event_id, host, "secret")[0] == 400
