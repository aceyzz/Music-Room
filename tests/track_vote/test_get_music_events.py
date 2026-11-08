"""GetMusicEvents (GET /v1/users/{user_public_id}/events, docs/todo.md §3) :
tout event que l'appelant peut voir -- les siens (n'importe quel rôle) plus
les publics de tout le monde. Routé via OpenFGA ListObjects(can_view), pas un
filtre host_id -- avant ce fix, un event où l'appelant était seulement invité
(jamais hôte) restait invisible ici alors que GetMusicEvent l'aurait laissé
passer (même trou que PlaylistService avant ListPlaylists)."""


def _ids(body):
    return {int(e["id"]) for e in body["events"]}


def test_lists_own_events_regardless_of_visibility(make_user, create_event, get_music_events):
    host = make_user()
    _, private = create_event(host, visibility="private")
    _, public = create_event(host, visibility="public")
    private_id = int(private["event"]["id"])
    public_id = int(public["event"]["id"])

    status, body = get_music_events(host, host)
    assert status == 200
    assert {private_id, public_id} <= _ids(body)


def test_sees_public_events_of_others_but_not_private_ones(make_user, create_event, get_music_events):
    host = make_user()
    stranger = make_user()
    _, private = create_event(host, visibility="private")
    _, public = create_event(host, visibility="public")
    private_id = int(private["event"]["id"])
    public_id = int(public["event"]["id"])

    status, body = get_music_events(stranger, stranger)
    assert status == 200
    assert public_id in _ids(body)
    assert private_id not in _ids(body)


def test_sees_a_private_event_they_were_invited_to_without_hosting_it(
    make_user, create_event, invite_to_event, get_music_events, eventually
):
    host = make_user()
    member = make_user()
    _, body = create_event(host, visibility="private")
    event_id = int(body["event"]["id"])
    status, _ = invite_to_event(event_id, host, member)
    assert status == 200

    status, body = eventually(
        lambda: get_music_events(member, member),
        lambda status, body: status == 200 and event_id in _ids(body),
    )
    assert status == 200
    assert event_id in _ids(body)


def test_cannot_list_another_users_events(make_user, create_event, get_music_events):
    """user_public_id est un CallerPublicIDField (policy.go) : demander la
    liste de quelqu'un d'autre est rejeté avant même d'atteindre le handler,
    pas juste filtré côté réponse -- ce n'est pas "browse tout le monde",
    seulement "ce que MOI je peux voir"."""
    host = make_user()
    stranger = make_user()
    create_event(host, visibility="public")

    status, _ = get_music_events(host, stranger)
    assert status == 403
