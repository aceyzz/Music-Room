"""Helpers propres à UserService (V.1 profil, préférences musicales, réseau
social), exposés en fixtures pour que chaque fichier de ce dossier les
utilise sans rien importer (voir tests/conftest.py pour les fixtures
partagées entre les quatre services : api, make_user, make_song,
make_friendship, tiny_png_base64, fetch_media, public_id_of, auth_headers,
eventually).

Toutes les routes de UserService authentifient l'appelant (bearer token) et
identifient les objets par leur public_id -- voir l'en-tête de
proto/music_room/v1/services/user_service.proto et
backend/internal/interceptor/policy.go. Chaque fixture ci-dessous convertit
donc l'id interne (int) que le test manipule en public_id juste avant
l'appel HTTP, et authentifie la requête au nom de l'"acteur" pertinent (celui
que policy.go nomme CallerPublicIDField pour cette RPC) -- les tests
eux-mêmes continuent de ne manipuler que des ids int."""

import pytest


@pytest.fixture
def upload_avatar(api, tiny_png_base64, public_id_of, auth_headers):
    def _upload(user_id, image_base64=None, content_type="image/png"):
        return api.post(
            f"/v1/users/{public_id_of(user_id)}/avatar",
            json={"image_data": image_base64 or tiny_png_base64, "content_type": content_type},
            headers=auth_headers(user_id),
        )

    return _upload


@pytest.fixture
def delete_avatar(api, public_id_of, auth_headers):
    def _delete(user_id):
        return api.delete(f"/v1/users/{public_id_of(user_id)}/avatar", headers=auth_headers(user_id))

    return _delete


@pytest.fixture
def get_user(api, public_id_of, auth_headers):
    """GET /v1/users/{public_id}?viewer_public_id=. `viewer_id` est
    désormais obligatoire : GetUser authentifie l'appelant, il n'existe plus
    de lecture "anonyme" (voir test_profile_visibility.py sur ce que devient
    ce cas)."""

    def _get(user_id, viewer_id):
        return api.get(
            f"/v1/users/{public_id_of(user_id)}",
            headers=auth_headers(viewer_id),
            viewer_public_id=public_id_of(viewer_id),
        )

    return _get


@pytest.fixture
def update_profile(api, public_id_of, auth_headers):
    """PATCH /v1/users/{user_public_id}/profile. Seuls les champs passés en
    kwargs atterrissent dans le corps JSON -- ne rien passer d'autre qu'un
    champ revient donc à laisser les autres "inchangés" (voir
    test_visibility.py sur ce que ça implique pour une chaîne vide). Route
    self-only (policy.go): user_id est toujours l'appelant."""

    def _update(user_id, **fields):
        return api.patch(
            f"/v1/users/{public_id_of(user_id)}/profile",
            json=fields,
            headers=auth_headers(user_id),
        )

    return _update


@pytest.fixture
def set_music_preferences(api, public_id_of, auth_headers):
    """PUT /v1/users/{user_public_id}/music-preferences. `preferences` est
    une liste de (deezer_genre_id, genre_name, weight) ; remplace tout
    l'ensemble existant, ce n'est pas un ajout. Route self-only."""

    def _set(user_id, preferences):
        return api.put(
            f"/v1/users/{public_id_of(user_id)}/music-preferences",
            json={"preferences": preferences},
            headers=auth_headers(user_id),
        )

    return _set


@pytest.fixture
def send_friend_request(api, public_id_of, auth_headers):
    def _send(requester_id, addressee_id, message=""):
        return api.post(
            f"/v1/users/{public_id_of(requester_id)}/friend-requests",
            json={"addressee_public_id": public_id_of(addressee_id), "message": message},
            headers=auth_headers(requester_id),
        )

    return _send


@pytest.fixture
def list_friend_requests(api, public_id_of, auth_headers):
    def _list(user_id, direction=None):
        params = {} if direction is None else {"direction": direction}
        return api.get(
            f"/v1/users/{public_id_of(user_id)}/friend-requests",
            headers=auth_headers(user_id),
            **params,
        )

    return _list


@pytest.fixture
def accept_friend_request(api, public_id_of, auth_headers):
    def _accept(request_id, addressee_id):
        return api.post(
            f"/v1/friend-requests/{request_id}/accept",
            json={"addressee_public_id": public_id_of(addressee_id)},
            headers=auth_headers(addressee_id),
        )

    return _accept


@pytest.fixture
def decline_friend_request(api, public_id_of, auth_headers):
    def _decline(request_id, addressee_id):
        return api.post(
            f"/v1/friend-requests/{request_id}/decline",
            json={"addressee_public_id": public_id_of(addressee_id)},
            headers=auth_headers(addressee_id),
        )

    return _decline


@pytest.fixture
def befriend(send_friend_request, accept_friend_request):
    """Fait passer deux utilisateurs par le vrai flux demande/acceptation
    (par opposition à make_friendship, qui insère la ligne directement en
    base) -- à utiliser quand le test veut juste "deux amis" comme donnée de
    départ, sans exercer le flux lui-même."""

    def _befriend(user_a, user_b):
        status, body = send_friend_request(user_a, user_b)
        assert status == 200, body
        request_id = int(body["request"]["id"])
        status, body = accept_friend_request(request_id, user_b)
        assert status == 200, body

    return _befriend


@pytest.fixture
def block_user(api, public_id_of, auth_headers):
    def _block(blocker_id, blocked_id):
        return api.post(
            f"/v1/users/{public_id_of(blocker_id)}/blocks",
            json={"blocked_public_id": public_id_of(blocked_id)},
            headers=auth_headers(blocker_id),
        )

    return _block


@pytest.fixture
def unblock_user(api, public_id_of, auth_headers):
    def _unblock(blocker_id, blocked_id):
        return api.delete(
            f"/v1/users/{public_id_of(blocker_id)}/blocks/{public_id_of(blocked_id)}",
            headers=auth_headers(blocker_id),
        )

    return _unblock


@pytest.fixture
def list_blocked_users(api, public_id_of, auth_headers):
    def _list(blocker_id):
        return api.get(
            f"/v1/users/{public_id_of(blocker_id)}/blocks",
            headers=auth_headers(blocker_id),
        )

    return _list
