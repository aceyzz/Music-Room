"""backend/internal/interceptor : l'authentification (est-ce un token
valide ?) est une préoccupation transversale aux quatre services, vérifiée
une seule fois avant toute autorisation -- voir authorize() dans
interceptor.go, qui lit le bearer token AVANT même de regarder quelle
policy s'applique. Chaque dossier de service teste déjà abondamment
l'AUTORISATION (qui a le droit de faire quoi une fois authentifié :
usurpation d'identité refusée, licences, visibilité...) mais aucun ne teste
directement l'AUTHENTIFICATION elle-même -- ce fichier comble ce trou une
fois pour toutes plutôt que de le dupliquer service par service, puisque
c'est le même mécanisme partagé qui est en jeu.

Un point volontairement PAS couvert ici : une méthode absente de la table
`policies` (refusée par défaut). Ce n'est pas testable en boîte noire --
toute RPC réellement exposée par la passerelle REST y figure forcément
(TestEveryRPCHasAPolicy, un test Go, fait échouer le build sinon), donc il
n'existe aucune route réelle pour exercer ce cas depuis l'extérieur."""

import hashlib
import secrets
import uuid

# Une route protégée par service (aucune n'est Public: true) -- le chemin
# n'a même pas besoin de désigner un objet réel : l'authentification est
# vérifiée avant toute résolution d'id (authorize() dans interceptor.go),
# donc un UUID inventé suffit à prouver que c'est bien LE TOKEN qui est
# refusé, pas l'objet qui est introuvable.
PROTECTED_ROUTES = [
    f"/v1/users/{uuid.uuid4()}",
    f"/v1/playlists/{uuid.uuid4()}",
    f"/v1/events/{uuid.uuid4()}",
    f"/v1/users/{uuid.uuid4()}/devices",
]


def test_missing_token_is_rejected_on_every_service(api):
    for route in PROTECTED_ROUTES:
        status, _ = api.get(route)
        assert status == 401, route


def test_garbage_token_is_rejected_on_every_service(api):
    headers = {"Authorization": "Bearer not-a-real-token"}
    for route in PROTECTED_ROUTES:
        status, _ = api.get(route, headers=headers)
        assert status == 401, route


def test_revoked_session_is_rejected(api, make_user, db_conn, public_id_of, auth_headers):
    """Authenticate refuse une session révoquée (ErrRevoked) -- vérifié ici
    via une route d'un service tiers (UserService), pas via AuthService.Logout
    lui-même : la garantie qui compte est que la révocation coupe l'accès
    PARTOUT, pas seulement sur le service qui l'a émise."""
    user = make_user()
    _, token = make_user.sessions[user]
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE user_sessions SET revoked_at = NOW(), revoked_reason = 'logout' "
            "WHERE token_hash = %s",
            (hashlib.sha256(token.encode()).digest(),),
        )

    status, _ = api.get(f"/v1/users/{public_id_of(user)}", headers=auth_headers(user))
    assert status == 401


def test_expired_session_is_rejected(api, make_user, db_conn, public_id_of, auth_headers):
    """Authenticate refuse une session dont expires_at est déjà passé
    (ErrExpired) -- même raisonnement que ci-dessus, vérifié sur un service
    tiers plutôt que sur AuthService."""
    user = make_user()
    _, token = make_user.sessions[user]
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE user_sessions SET expires_at = NOW() - INTERVAL '1 minute' "
            "WHERE token_hash = %s",
            (hashlib.sha256(token.encode()).digest(),),
        )

    status, _ = api.get(f"/v1/users/{public_id_of(user)}", headers=auth_headers(user))
    assert status == 401


def test_identity_resolved_from_the_token_is_stable_across_services(
    api, make_user, public_id_of, auth_headers
):
    """Un token authentifie une SESSION, pas une route : l'identité qu'il
    résout est la même quel que soit le service auquel on le présente.
    UpdateUserProfile est self-only (policy.go : le champ vérifié EST celui
    qui identifie l'appelant), donc le seul moyen d'y agir "en tant que bob"
    est de présenter le token de bob -- celui d'alice reste alice, refusé
    dès qu'il prétend être quelqu'un d'autre (même vérification que
    tests/user/test_not_found.py, reprise ici du point de vue
    "authentification transversale" plutôt que "un service en particulier")."""
    alice = make_user()
    bob = make_user()

    status, body = api.patch(
        f"/v1/users/{public_id_of(alice)}/profile",
        json={"first_name": "Alice"},
        headers=auth_headers(alice),
    )
    assert status == 200
    assert body["user"]["firstName"] == "Alice"

    # Le token d'alice ne devient pas celui de bob en changeant juste l'id
    # dans l'URL.
    status, _ = api.patch(
        f"/v1/users/{public_id_of(bob)}/profile",
        json={"first_name": "Not Bob"},
        headers=auth_headers(alice),
    )
    assert status == 403
