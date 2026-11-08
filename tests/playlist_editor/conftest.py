"""Helpers propres à Music Playlist Editor (V.2.3), exposés en fixtures pour
que chaque fichier de ce dossier les utilise sans rien importer (voir
tests/conftest.py pour les fixtures partagées entre les quatre services :
api, make_user, make_song, make_friendship, tiny_png_base64, fetch_media,
public_id_of, auth_headers, eventually).

Comme pour UserService (voir tests/user/conftest.py), chaque route identifie
ses objets par public_id et authentifie l'appelant par bearer token -- voir
l'en-tête de proto/music_room/v1/services/playlist_service.proto et
backend/internal/interceptor/policy.go. Un champ CallerPublicIDField qui
n'est PAS lié à l'URL (ex. user_public_id sur AddSongToPlaylist) n'a pas
besoin d'être envoyé explicitement : vide, l'intercepteur le remplit avec
l'identité de la session -- seuls les champs liés au chemin (playlist_public_id)
ou désignant un AUTRE utilisateur (invitee_user_public_id) sont fournis
ci-dessous.

`create_playlist` retient le public_id de chaque playlist créée (indexé par
son id interne, comme make_user le fait pour les utilisateurs) pour que le
reste de ce fichier -- et les tests -- continuent de manipuler des
playlist_id entiers. Elle attend aussi que la tuple `owner` fraîchement
écrite (asynchrone, via l'outbox -- voir tests/conftest.py:eventually) soit
effectivement visible avant de rendre la main, pour que CHAQUE test qui agit
sur sa playlist juste après l'avoir créée n'ait pas à courir contre le
worker individuellement."""

import pytest


@pytest.fixture
def create_playlist(api, public_id_of, auth_headers, eventually):
    public_ids = {}

    def _create(owner_id, **overrides):
        payload = {"name": overrides.pop("name", "My Mix")}
        payload.update(overrides)
        status, body = api.post("/v1/playlists", json=payload, headers=auth_headers(owner_id))
        if status == 200:
            playlist_id = int(body["playlist"]["id"])
            playlist_public_id = body["playlist"]["publicId"]
            public_ids[playlist_id] = playlist_public_id
            eventually(
                lambda: api.get(
                    f"/v1/playlists/{playlist_public_id}", headers=auth_headers(owner_id)
                ),
                lambda status, _: status == 200,
            )
        return status, body

    _create.public_ids = public_ids
    return _create


@pytest.fixture
def playlist_public_id_of(create_playlist):
    def _pid(playlist_id: int) -> str:
        return create_playlist.public_ids[playlist_id]

    return _pid


@pytest.fixture
def get_playlist(api, auth_headers, playlist_public_id_of):
    def _get(playlist_id, viewer_id):
        return api.get(
            f"/v1/playlists/{playlist_public_id_of(playlist_id)}", headers=auth_headers(viewer_id)
        )

    return _get


@pytest.fixture
def list_playlists(api, auth_headers):
    def _list(viewer_id):
        return api.get("/v1/playlists", headers=auth_headers(viewer_id))

    return _list


@pytest.fixture
def list_ops(api, auth_headers, playlist_public_id_of):
    def _list(playlist_id, viewer_id, since_revision=0):
        return api.get(
            f"/v1/playlists/{playlist_public_id_of(playlist_id)}/ops",
            headers=auth_headers(viewer_id),
            since_revision=since_revision,
        )

    return _list


@pytest.fixture
def add_song(api, auth_headers, playlist_public_id_of):
    def _add(playlist_id, song, user_id):
        return api.post(
            f"/v1/playlists/{playlist_public_id_of(playlist_id)}/songs",
            json={"deezer_song_id": song["deezer_song_id"]},
            headers=auth_headers(user_id),
        )

    return _add


@pytest.fixture
def move_song(api, auth_headers, playlist_public_id_of):
    def _move(playlist_id, playlist_song_id, after_playlist_song_id, user_id):
        return api.patch(
            f"/v1/playlists/{playlist_public_id_of(playlist_id)}/songs/{playlist_song_id}/position",
            json={"after_playlist_song_id": after_playlist_song_id},
            headers=auth_headers(user_id),
        )

    return _move


@pytest.fixture
def remove_song(api, auth_headers, playlist_public_id_of):
    def _remove(playlist_id, playlist_song_id, user_id):
        return api.delete(
            f"/v1/playlists/{playlist_public_id_of(playlist_id)}/songs/{playlist_song_id}",
            headers=auth_headers(user_id),
        )

    return _remove


@pytest.fixture
def set_visibility(api, auth_headers, playlist_public_id_of):
    """Pas de CallerPublicIDField sur SetPlaylistVisibility (policy.go) :
    n'importe quel appelant authentifié avec la permission peut agir, donc
    cette fixture prend un `actor_id` explicite plutôt que de le déduire."""

    def _set(playlist_id, visibility, actor_id):
        return api.patch(
            f"/v1/playlists/{playlist_public_id_of(playlist_id)}/visibility",
            json={"visibility": visibility},
            headers=auth_headers(actor_id),
        )

    return _set


@pytest.fixture
def set_edit_license(api, auth_headers, playlist_public_id_of):
    """Pas de CallerPublicIDField sur SetPlaylistEditLicense (policy.go),
    même raisonnement que set_visibility ci-dessus."""

    def _set(playlist_id, edit_license, actor_id):
        return api.patch(
            f"/v1/playlists/{playlist_public_id_of(playlist_id)}/edit-license",
            json={"edit_license": edit_license},
            headers=auth_headers(actor_id),
        )

    return _set


@pytest.fixture
def rename_playlist(api, auth_headers, playlist_public_id_of):
    """Pas de CallerPublicIDField sur RenamePlaylist (policy.go) non plus,
    même raisonnement que set_visibility ci-dessus."""

    def _rename(playlist_id, name, actor_id):
        return api.patch(
            f"/v1/playlists/{playlist_public_id_of(playlist_id)}/name",
            json={"name": name},
            headers=auth_headers(actor_id),
        )

    return _rename


@pytest.fixture
def invite_to_playlist(api, public_id_of, auth_headers, playlist_public_id_of):
    def _invite(playlist_id, inviter_id, invitee_id):
        return api.post(
            f"/v1/playlists/{playlist_public_id_of(playlist_id)}/members",
            json={"invitee_user_public_id": public_id_of(invitee_id)},
            headers=auth_headers(inviter_id),
        )

    return _invite


@pytest.fixture
def set_playlist_cover(api, tiny_png_base64, auth_headers, playlist_public_id_of):
    def _set(playlist_id, user_id, image_base64=None, content_type="image/png"):
        return api.post(
            f"/v1/playlists/{playlist_public_id_of(playlist_id)}/cover",
            json={"image_data": image_base64 or tiny_png_base64, "content_type": content_type},
            headers=auth_headers(user_id),
        )

    return _set


@pytest.fixture
def transfer_ownership(api, public_id_of, auth_headers, playlist_public_id_of):
    def _transfer(playlist_id, new_owner_id, current_owner_id):
        return api.post(
            f"/v1/playlists/{playlist_public_id_of(playlist_id)}/ownership-transfer",
            json={"new_owner_user_public_id": public_id_of(new_owner_id)},
            headers=auth_headers(current_owner_id),
        )

    return _transfer


@pytest.fixture
def delete_playlist(api, auth_headers, playlist_public_id_of):
    def _delete(playlist_id, user_id):
        return api.delete(
            f"/v1/playlists/{playlist_public_id_of(playlist_id)}", headers=auth_headers(user_id)
        )

    return _delete


@pytest.fixture
def delete_playlist_cover(api, auth_headers, playlist_public_id_of):
    def _delete(playlist_id, user_id):
        return api.delete(
            f"/v1/playlists/{playlist_public_id_of(playlist_id)}/cover",
            headers=auth_headers(user_id),
        )

    return _delete
