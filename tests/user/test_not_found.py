"""Un id qui n'existe pas reste un 404 simple (par opposition à une donnée
existante mais cachée par la visibilité, couvert par
test_profile_visibility.py et test_friends.py).

GetUser est la seule des trois routes ci-dessous dont la cible (public_id
dans le chemin) est un objet DIFFÉRENT de l'appelant (viewer_public_id) --
c'est donc la seule où "cet id n'existe pas" reste atteignable de l'extérieur
avec le nouvel intercepteur. UpdateUserProfile et SetMusicPreferences sont
self-only (policy.go : le champ vérifié EST le champ qui identifie
l'appelant) : un client ne peut plus jamais nommer un id "autre", connu ou
non -- stampCaller refuse toute valeur qui ne correspond pas à la session
avant même d'atteindre la vérification de permission. Ce que ces deux routes
peuvent désormais révéler, ce n'est plus "id inconnu", mais "usurpation
refusée" -- ce que les deux tests ci-dessous vérifient à la place."""

import uuid


def test_get_user_with_unknown_id_is_not_found(api, make_user, public_id_of, auth_headers):
    viewer = make_user()
    unknown_public_id = str(uuid.uuid4())

    status, _ = api.get(
        f"/v1/users/{unknown_public_id}",
        headers=auth_headers(viewer),
        viewer_public_id=public_id_of(viewer),
    )
    assert status == 404


def test_update_profile_claiming_someone_elses_identity_is_denied(
    api, make_user, public_id_of, auth_headers
):
    """update_profile(user_id, ...) (la fixture) ne peut pas construire ce
    cas -- elle authentifie toujours l'appelant comme le user_id qu'on lui
    passe. Ici on authentifie explicitement `impostor` mais on prétend être
    `victim` dans le corps : stampCaller (interceptor.go) doit refuser avant
    la moindre écriture."""
    impostor = make_user()
    victim = make_user()

    # Le chemin est celui de victim (grpc-gateway le lie à user_public_id),
    # mais le token authentifie impostor : l'un des deux doit céder, et c'est
    # stampCaller qui tranche, avant toute lecture/écriture côté profil.
    status, _ = api.patch(
        f"/v1/users/{public_id_of(victim)}/profile",
        json={"first_name": "Alice"},
        headers=auth_headers(impostor),
    )
    assert status == 403


def test_set_music_preferences_claiming_someone_elses_identity_is_denied(
    api, make_user, public_id_of, auth_headers
):
    impostor = make_user()
    victim = make_user()

    status, _ = api.put(
        f"/v1/users/{public_id_of(victim)}/music-preferences",
        json={
            "user_public_id": public_id_of(victim),
            "preferences": [{"deezer_genre_id": 132, "genre_name": "Pop", "weight": 5}],
        },
        headers=auth_headers(impostor),
    )
    assert status == 403
