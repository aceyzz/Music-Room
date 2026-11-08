"""DeleteEvent (docs/todo.md §3) : soft-delete (deleted_at), host-only --
can_delete n'inclut pas admin, contrairement à can_change_status. Légal
depuis n'importe quel statut, contrairement à Start/Pause/Resume/End."""


def test_host_deletes_the_event(make_user, create_event, delete_event, get_event):
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    assert body["event"]["deletedAt"] == "0"

    status, body = delete_event(event_id, host)
    assert status == 200
    assert body["event"]["deletedAt"] != "0"

    # deleted_at IS NULL filtre toute lecture -- l'événement devient
    # introuvable, y compris pour son hôte.
    status, _ = get_event(event_id, host)
    assert status == 404


def test_non_host_cannot_delete(make_user, create_event, invite_to_event, delete_event, eventually):
    host = make_user()
    member = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    invite_to_event(event_id, host, member)

    status, _ = eventually(
        lambda: delete_event(event_id, member),
        lambda status, _: status != 404,  # laisse le temps à l'invitation.
    )
    assert status == 403


def test_deleting_twice_is_denied_the_second_time(make_user, create_event, delete_event):
    """Même comportement que DeletePlaylist : la deuxième suppression ne
    peut plus atteindre le handler -- deleted_at IS NULL fait déjà échouer
    la résolution de l'UUID public au niveau de l'intercepteur."""
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    assert delete_event(event_id, host)[0] == 200

    status, _ = delete_event(event_id, host)
    assert status == 403


def test_deletable_from_any_status(make_user, create_event, set_event_status, delete_event):
    """Contrairement à Start/Pause/Resume/End, pas de garde de statut :
    peut supprimer un événement 'live' (docs/permissions.md §13 ne pose
    aucune restriction, à l'inverse des quatre transitions)."""
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    set_event_status(event_id, "live")

    status, body = delete_event(event_id, host)
    assert status == 200
