"""RemoveQueueEntry (docs/todo.md §3, docs/permissions.md §12) :
queue_entry#can_remove = suggester OR can_manage_queue from parent (host ou
admin) -- pas encore branché avant ce fix (authz/model.fga)."""


def _queued_ids(body):
    return {int(e["id"]) for e in body["queue"]}


def test_suggester_can_remove_their_own_entry(make_user, make_song, create_event, suggest, remove_queue_entry):
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    suggest(event_id, host, make_song())  # auto-starts, becomes 'playing'.
    status, body = suggest(event_id, host, make_song())  # stays queued.
    entry_id = int(body["queue"][0]["id"])

    status, body = remove_queue_entry(event_id, entry_id, host)
    assert status == 200
    assert entry_id not in _queued_ids(body)


def test_host_can_remove_someone_elses_suggestion(
    make_user, make_song, create_event, invite_to_event, suggest, remove_queue_entry, eventually
):
    host = make_user()
    member = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    invite_to_event(event_id, host, member)
    suggest(event_id, host, make_song())  # keeps the radio busy so the next stays queued.

    status, body = eventually(
        lambda: suggest(event_id, member, make_song()),
        lambda status, _: status != 403,  # laisse le temps à l'invitation.
    )
    assert status == 200
    entry_id = int(body["queue"][0]["id"])

    status, body = remove_queue_entry(event_id, entry_id, host)
    assert status == 200
    assert entry_id not in _queued_ids(body)


def test_non_suggester_non_host_cannot_remove(
    make_user, make_song, create_event, invite_to_event, suggest, remove_queue_entry, eventually
):
    host = make_user()
    suggester = make_user()
    bystander = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    invite_to_event(event_id, host, suggester)
    invite_to_event(event_id, host, bystander)
    suggest(event_id, host, make_song())

    status, body = eventually(
        lambda: suggest(event_id, suggester, make_song()),
        lambda status, _: status != 403,
    )
    assert status == 200
    entry_id = int(body["queue"][0]["id"])

    status, _ = eventually(
        lambda: remove_queue_entry(event_id, entry_id, bystander),
        lambda status, _: status != 404,
    )
    assert status == 403


def test_cannot_remove_an_entry_that_is_already_playing(
    make_user, make_song, create_event, suggest, play_next, remove_queue_entry
):
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    suggest(event_id, host, make_song())  # auto-starts, keeps the radio busy.
    # Captured while still queued -- entry_public_ids only ever learns an id
    # from a `queue` array, and a 'playing' entry never appears in one
    # (PlayNextInEventQueueResponse: "the song that just started is no
    # longer listed").
    status, body = suggest(event_id, host, make_song())
    entry_id = int(body["queue"][0]["id"])

    status, _ = play_next(event_id, host)  # advances: entry_id is now 'playing'.
    assert status == 200

    status, _ = remove_queue_entry(event_id, entry_id, host)
    assert status == 400  # FailedPrecondition


def test_removed_song_can_be_resuggested(make_user, make_song, create_event, suggest, remove_queue_entry):
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    song = make_song()
    status, body = suggest(event_id, host, song)
    entry_id = int(body["queue"][0]["id"])
    remove_queue_entry(event_id, entry_id, host)

    status, body = suggest(event_id, host, song)
    assert status == 200
