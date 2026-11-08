"""SetPlaylistVisibility : changer public/privé après création."""


def test_owner_can_change_visibility_after_creation(
    api, make_user, create_playlist, get_playlist, set_visibility, eventually
):
    """La visibilité n'est pas figée à la création : ce test vérifie que le
    changement a un effet réel sur les lectures suivantes (un outsider qui
    voyait la playlist publique doit en être exclu une fois qu'elle passe en
    privé), pas juste que l'appel renvoie 200."""
    owner = make_user()
    outsider = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])
    assert get_playlist(playlist_id, outsider)[0] == 200

    status, body = set_visibility(playlist_id, "private", owner)
    assert status == 200
    assert body["playlist"]["visibility"] == "private"

    # Eventually, not at once: the change reaches OpenFGA through the outbox
    # (~1 s), then its Check cache drops the old answer (cache controller,
    # ~1-2 s, docker-compose.yaml). Staleness accepted for the load test.
    status, _ = eventually(
        lambda: get_playlist(playlist_id, outsider),
        lambda status, _: status == 404,
        timeout=5.0,
    )
    assert status == 404
    assert get_playlist(playlist_id, owner)[0] == 200


def test_non_owner_cannot_change_visibility(api, make_user, create_playlist, set_visibility):
    """can_change_visibility: owner or admin (policy.go) -- désormais
    vérifié par l'intercepteur (ça ne l'était pas avant lui : un tiers
    pouvait changer la visibilité de n'importe quelle playlist)."""
    owner = make_user()
    someone_else = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])

    status, _ = set_visibility(playlist_id, "private", someone_else)
    assert status == 403
