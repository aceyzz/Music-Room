"""V.1 : "state their musical preferences (musical genres)". SetMusicPreferences
remplace tout l'ensemble (delete + reinsert), ce n'est jamais un ajout."""


def test_set_replaces_the_whole_set(get_user, set_music_preferences, make_user):
    """Poser un deuxième ensemble de préférences doit faire disparaître le
    premier, pas s'y ajouter -- le client envoie toujours l'état complet de
    son sélecteur de genres."""
    user = make_user()
    status, body = set_music_preferences(
        user,
        [
            {"deezer_genre_id": 132, "genre_name": "Pop", "weight": 5},
            {"deezer_genre_id": 152, "genre_name": "Rock", "weight": 3},
        ],
    )
    assert status == 200
    assert {p["genreName"] for p in body["preferences"]} == {"Pop", "Rock"}

    status, body = set_music_preferences(
        user, [{"deezer_genre_id": 106, "genre_name": "Electro", "weight": 4}]
    )
    assert status == 200
    genres = {p["genreName"] for p in body["preferences"]}
    assert genres == {"Electro"}

    status, body = get_user(user, viewer_id=user)
    assert status == 200
    assert {p["genreName"] for p in body["user"]["musicPreferences"]} == {"Electro"}


def test_weight_out_of_range_is_rejected(set_music_preferences, make_user):
    user = make_user()
    status, _ = set_music_preferences(
        user, [{"deezer_genre_id": 132, "genre_name": "Pop", "weight": 6}]
    )
    assert status == 400


def test_preferences_hidden_when_visibility_is_private(
    get_user, update_profile, set_music_preferences, make_user
):
    """preferences_visibility est public par défaut ; en private, un
    stranger ne doit plus voir la liste (le propriétaire, lui, continue)."""
    owner = make_user()
    stranger = make_user()
    set_music_preferences(owner, [{"deezer_genre_id": 132, "genre_name": "Pop", "weight": 5}])
    update_profile(owner, preferences_visibility="private")

    status, body = get_user(owner, viewer_id=stranger)
    assert status == 200
    assert body["user"]["musicPreferences"] == []

    status, body = get_user(owner, viewer_id=owner)
    assert status == 200
    assert len(body["user"]["musicPreferences"]) == 1
