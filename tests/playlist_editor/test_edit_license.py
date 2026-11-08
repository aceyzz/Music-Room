"""V.2.3 : par défaut tout le monde peut éditer ; avec "invited_only" seuls
les membres invités le peuvent."""


def test_invited_only_restricts_editing(
    make_user, make_song, create_playlist, invite_to_playlist, add_song, eventually
):
    """Avec edit_license="invited_only", ajouter un morceau doit être réservé
    aux membres (propriétaire inclus) : un utilisateur quelconque, même s'il
    peut voir la playlist (ici publique par défaut côté visibilité -- seule
    l'édition est restreinte), ne peut pas y ajouter de morceau tant qu'il
    n'a pas été invité."""
    owner = make_user()
    member = make_user()
    outsider = make_user()
    _, body = create_playlist(owner, edit_license="invited_only")
    playlist_id = int(body["playlist"]["id"])
    status, _ = invite_to_playlist(playlist_id, owner, member)
    assert status == 200
    song = make_song()

    # Non-membre : refusé.
    status, _ = add_song(playlist_id, song, outsider)
    assert status == 403

    # Membre invité : accepté (la tuple viewer/editor écrite par l'invitation
    # passe par l'outbox, voir tests/conftest.py:eventually).
    status, body = eventually(
        lambda: add_song(playlist_id, song, member), lambda status, _: status == 200
    )
    assert status == 200
    assert body["playlist"]["songCount"] == 1


def test_open_edit_license_does_not_override_private_visibility(
    make_user, make_song, create_playlist, add_song
):
    """Nuance explicitement soulignée par le commentaire de
    playlist_service.proto/authz/model.fga : can_edit_songs est
    `can_view AND open_edit`, jamais `open_edit` seul -- une licence
    "everyone" n'ouvre donc l'édition qu'à qui peut DÉJÀ voir la playlist.
    Sur une playlist privée, un outsider qui ne la voit même pas reste
    bloqué malgré edit_license="everyone" (le défaut), ce qui serait facile
    à rater en ne testant que le cas "invited_only" (voir le test
    précédent)."""
    owner = make_user()
    outsider = make_user()
    _, body = create_playlist(owner, visibility="private")
    playlist_id = int(body["playlist"]["id"])
    assert body["playlist"]["editLicense"] == "everyone"  # default, confirmed here on purpose.

    status, _ = add_song(playlist_id, make_song(), outsider)
    assert status == 403


def test_owner_can_change_the_license_after_creation(
    make_user, make_song, create_playlist, set_edit_license, add_song, eventually
):
    """SetPlaylistEditLicense (docs/todo.md §2) : la licence n'est pas figée
    à la création. Le changement doit avoir un effet réel sur les appels
    suivants (miroir de test_settings.py::test_owner_can_change_visibility_after_creation
    pour SetPlaylistVisibility)."""
    owner = make_user()
    outsider = make_user()
    _, body = create_playlist(owner)  # default edit_license="everyone"
    playlist_id = int(body["playlist"]["id"])
    assert add_song(playlist_id, make_song(), outsider)[0] == 200

    status, body = set_edit_license(playlist_id, "invited_only", owner)
    assert status == 200
    assert body["playlist"]["editLicense"] == "invited_only"

    # Eventually, not at once: the change reaches OpenFGA through the outbox
    # (~1 s), then its Check cache drops the old answer (cache controller,
    # ~1-2 s, docker-compose.yaml). Staleness accepted for the load test.
    status, _ = eventually(
        lambda: add_song(playlist_id, make_song(), outsider),
        lambda status, _: status == 403,
        timeout=5.0,
    )
    assert status == 403


def test_non_owner_cannot_change_the_license(make_user, create_playlist, set_edit_license):
    """can_change_license: owner or admin (authz/model.fga) -- vérifié par
    l'intercepteur, même raisonnement que SetPlaylistVisibility."""
    owner = make_user()
    someone_else = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])

    status, _ = set_edit_license(playlist_id, "invited_only", someone_else)
    assert status == 403
