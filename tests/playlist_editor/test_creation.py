"""CreatePlaylist : valeurs par défaut."""


def test_defaults_to_public_everyone(api, make_user, create_playlist):
    """Le sujet est explicite pour ce service aussi : "By default, a
    playlist is public" et "By default, everyone can edit the playlist" --
    ne rien préciser à la création doit appliquer ces défauts plutôt que
    d'exiger que le client les fournisse à chaque fois."""
    owner = make_user()
    status, body = create_playlist(owner)
    assert status == 200
    playlist = body["playlist"]
    assert playlist["visibility"] == "public"
    assert playlist["editLicense"] == "everyone"
    assert int(playlist["ownerId"]) == owner
    assert int(playlist["revision"]) == 0
