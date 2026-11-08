"""Un id qui n'existe pas (par opposition à un id existant mais interdit,
couvert par test_visibility.py) reste un 404 simple."""

import uuid


def test_get_playlist_with_unknown_id_is_not_found(api, make_user, auth_headers):
    """Lecture simple sur un playlist_id qui n'a jamais existé : doit
    répondre 404 proprement plutôt que de planter (ex. sur un scan
    NULL/erreur SQL non gérée)."""
    viewer = make_user()
    status, _ = api.get(f"/v1/playlists/{uuid.uuid4()}", headers=auth_headers(viewer))
    assert status == 404


def test_remove_song_from_unknown_playlist_is_denied(api, make_user, auth_headers):
    """Même chose côté mutation, mais RemoveSongFromPlaylist ne porte pas
    NotFound:true (policy.go) -- à la différence de GetPlaylist, ce n'est pas
    une route de lecture, donc distinguer "n'existe pas" de "refusé" n'y est
    pas une fuite : can_edit_songs échoue simplement comme sur n'importe quel
    objet inconnu, d'où 403 et non 404."""
    owner = make_user()
    status, _ = api.delete(
        f"/v1/playlists/{uuid.uuid4()}/songs/1", headers=auth_headers(owner)
    )
    assert status == 403
