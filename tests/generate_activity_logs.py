"""Script manuel, pas une suite pytest automatisée : contrairement à
`make_user` (tests/conftest.py), l'utilisateur créé ici n'est PAS supprimé à
la fin -- exprès, pour que `activity_logs.user_id` reste peuplé après coup
(la colonne a `ON DELETE SET NULL`, voir db/schema/00014_activity_logs.sql).
Le nom du fichier ne commence pas par `test_` : `pytest tests -q` (la suite
automatisée / `make api-test`) ne le ramasse jamais tout seul.

Usage :
    tests/.venv/bin/python3 tests/generate_activity_logs.py

Rejoue un appel par code gRPC courant (voir la table dans SCENARIOS
ci-dessous), avec les trois headers V.6 sur le tout premier pour qu'il reste
un exemple visible de `metadata` rempli -- les suivants n'en portent pas,
pour qu'un `{}` normal reste visible aussi. Imprime les lignes
correspondantes directement, sans attendre un `make activity-logs` séparé
(que ce script suggère quand même à la fin, pour rejouer la même vue plus
tard)."""

import hashlib
import os
import secrets
import time
import uuid

import psycopg2
import requests

BASE_URL = os.environ.get("API_BASE_URL", "http://localhost:8081")
DB_DSN = os.environ["TEST_DATABASE_URL"]
OPENFGA_URL = os.environ.get("OPENFGA_API_URL", "http://localhost:8082")
OPENFGA_STORE_ID = os.environ.get("OPENFGA_STORE_ID", "01MRAVTHZ00000000000000000")


def make_persistent_user(conn, display_name):
    """Même geste que tests/conftest.py:make_user, sans le nettoyage."""
    email = f"{display_name}@example.test"
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO users (display_name, email) VALUES (%s, %s) RETURNING id, public_id",
            (display_name, email),
        )
        user_id, public_id = cur.fetchone()

        token = secrets.token_urlsafe(32)
        token_hash = hashlib.sha256(token.encode()).digest()
        cur.execute(
            "INSERT INTO user_sessions (user_id, token_hash, expires_at) "
            "VALUES (%s, %s, NOW() + INTERVAL '1 day')",
            (user_id, token_hash),
        )
    public_id = str(public_id)

    # account_owner + anyone : sans elles, meme le proprietaire ne peut rien
    # faire sur son propre compte (voir internal/authz/tuple.go:NewUser).
    requests.post(
        f"{OPENFGA_URL}/stores/{OPENFGA_STORE_ID}/write",
        json={
            "writes": {
                "tuple_keys": [
                    {"user": f"user:{public_id}", "relation": "account_owner", "object": f"user:{public_id}"},
                    {"user": "user:*", "relation": "anyone", "object": f"user:{public_id}"},
                ]
            }
        },
        timeout=10,
    ).raise_for_status()

    return user_id, public_id, token


def event_times():
    """CreateEvent requires both times: starting now, for three hours."""
    now = int(time.time())
    return {"startsAt": str(now), "endsAt": str(now + 3 * 3600)}


def make_song(conn):
    """Même geste que tests/conftest.py:make_song : insère directement dans
    le cache Deezer local plutôt que d'appeler la vraie API Deezer."""
    deezer_song_id = uuid.uuid4().int % 900_000_000 + 100_000_000
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO songs (deezer_song_id, title, duration_seconds, artist_name) "
            "VALUES (%s, %s, %s, %s) RETURNING id",
            (deezer_song_id, f"song-{uuid.uuid4().hex[:8]}", 180, "Demo Artist"),
        )
    return deezer_song_id


def print_logs_since(conn, user_id, since):
    """since borne la fenêtre : sans elle, `user_id IS NULL` remonterait
    aussi toutes les lignes anonymisées après coup par un DELETE CASCADE
    d'un tout autre run (ON DELETE SET NULL, voir l'en-tête du fichier) --
    des centaines sur une base qui a déjà vu tourner la suite pytest."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT created_at, action, user_id, resource_type, resource_id, result_code, metadata "
            "FROM activity_logs WHERE created_at >= %s AND (user_id = %s OR user_id IS NULL) "
            "ORDER BY created_at",
            (since, user_id),
        )
        rows = cur.fetchall()
    print(f"\n{len(rows)} ligne(s) dans activity_logs :\n")
    print(f"{'action':<48} {'user_id':<8} {'resource':<18} {'result_code':<12} metadata")
    for _, action, uid, resource_type, resource_id, result_code, metadata in rows:
        resource = f"{resource_type}:{resource_id}" if resource_type else ""
        print(f"{action:<48} {str(uid or ''):<8} {resource:<18} {result_code:<12} {metadata}")


def main():
    conn = psycopg2.connect(DB_DSN)
    conn.autocommit = True

    run_started_at = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime())
    suffix = uuid.uuid4().hex[:8]
    user_id, public_id, token = make_persistent_user(conn, f"activity-log-demo-{suffix}")
    print(f"Utilisateur persistant créé : id={user_id} public_id={public_id}")
    print("(pas supprimé -- retrouvable ensuite via `make activity-logs` ou par ce public_id)")

    # Un deuxième compte pour les scénarios UserService qui ciblent
    # quelqu'un d'autre (demande d'ami, blocage) -- lui aussi persistant.
    _, second_public_id, _ = make_persistent_user(conn, f"activity-log-demo-target-{suffix}")

    auth = {"Authorization": f"Bearer {token}"}
    headers_with_metadata = {
        **auth,
        "x-platform": "ios",
        "x-device-model": "iPhone15,3",
        "x-app-version": "1.2.3",
    }

    # Un peu de matière pour les scénarios qui ont besoin d'un objet réel
    # (Aborted, AlreadyExists) : une playlist avec un morceau, un event.
    r = requests.post(f"{BASE_URL}/v1/playlists", json={"name": "Demo playlist"}, headers=auth, timeout=10)
    playlist_id = r.json()["playlist"]["publicId"]
    demo_song = make_song(conn)
    r = requests.post(
        f"{BASE_URL}/v1/playlists/{playlist_id}/songs",
        json={"deezer_song_id": demo_song},
        headers=auth,
        timeout=10,
    )
    playlist_song_id = r.json()["songs"][0]["id"]

    r = requests.post(f"{BASE_URL}/v1/events", json={"name": "Demo event", **event_times()}, headers=auth, timeout=10)
    event_id = r.json()["event"]["publicId"]
    # Un deuxième event, séparé du premier : le scénario AlreadyExists
    # suggère un morceau dans "event_id" ci-dessus. Sans un event à part,
    # jamais suggéré, le scénario FailedPrecondition (lecture d'une file
    # vide) réussirait au lieu d'échouer.
    r = requests.post(f"{BASE_URL}/v1/events", json={"name": "Demo event (never started)", **event_times()}, headers=auth, timeout=10)
    never_started_event_id = r.json()["event"]["publicId"]

    # (description, code gRPC attendu, appel)
    SCENARIOS = [
        (
            "0 OK -- succès authentifié, avec les 3 headers V.6",
            0,
            lambda: requests.post(
                f"{BASE_URL}/v1/playlists",
                json={"name": "Activity log demo"},
                headers=headers_with_metadata,
                timeout=10,
            ),
        ),
        (
            "3 InvalidArgument -- champ requis manquant (name vide)",
            3,
            lambda: requests.post(f"{BASE_URL}/v1/playlists", json={"name": ""}, headers=auth, timeout=10),
        ),
        (
            "5 NotFound -- lecture d'une playlist inexistante",
            5,
            lambda: requests.get(f"{BASE_URL}/v1/playlists/{uuid.uuid4()}", headers=auth, timeout=10),
        ),
        (
            "6 AlreadyExists -- même morceau suggéré deux fois au même event",
            6,
            lambda: [
                requests.post(
                    f"{BASE_URL}/v1/events/{event_id}/queue",
                    json={"deezer_song_id": demo_song},
                    headers=auth,
                    timeout=10,
                ),
                requests.post(
                    f"{BASE_URL}/v1/events/{event_id}/queue",
                    json={"deezer_song_id": demo_song},
                    headers=auth,
                    timeout=10,
                ),
            ][-1],
        ),
        (
            "7 PermissionDenied -- suppression d'une playlist inexistante",
            7,
            lambda: requests.delete(f"{BASE_URL}/v1/playlists/{uuid.uuid4()}", headers=auth, timeout=10),
        ),
        (
            "9 FailedPrecondition -- lecture d'un event dont la file est vide",
            9,
            lambda: requests.post(
                f"{BASE_URL}/v1/events/{never_started_event_id}/playback/next", json={}, headers=auth, timeout=10
            ),
        ),
        (
            "10 Aborted -- déplacement de morceau avec base_revision périmée",
            10,
            lambda: requests.patch(
                f"{BASE_URL}/v1/playlists/{playlist_id}/songs/{playlist_song_id}",
                json={"to_position": 0, "base_revision": 999},
                headers=auth,
                timeout=10,
            ),
        ),
        (
            "16 Unauthenticated -- token invalide",
            16,
            lambda: requests.post(
                f"{BASE_URL}/v1/playlists",
                json={"name": "x"},
                headers={"Authorization": "Bearer not-a-real-token"},
                timeout=10,
            ),
        ),
        # -- UserService / DelegationService : mêmes garanties (headers,
        # resource_type/resource_id, denials), sur d'autres services que
        # Playlist/Event ci-dessus.
        (
            "0 OK -- UserService.GetUser (lecture de son propre profil)",
            0,
            lambda: requests.get(f"{BASE_URL}/v1/users/{public_id}", headers=auth, timeout=10),
        ),
        (
            "0 OK -- UserService.SendFriendRequest",
            0,
            lambda: requests.post(
                f"{BASE_URL}/v1/users/{public_id}/friend-requests",
                json={"addressee_public_id": second_public_id},
                headers=auth,
                timeout=10,
            ),
        ),
        (
            "0 OK -- UserService.BlockUser",
            0,
            lambda: requests.post(
                f"{BASE_URL}/v1/users/{public_id}/blocks",
                json={"blocked_public_id": second_public_id},
                headers=auth,
                timeout=10,
            ),
        ),
        (
            "0 OK -- DelegationService.RegisterDevice",
            0,
            lambda: requests.post(
                f"{BASE_URL}/v1/users/{public_id}/devices",
                json={"device_identifier": f"demo-{suffix}", "name": "Demo iPhone", "platform": "ios"},
                headers=auth,
                timeout=10,
            ),
        ),
        (
            "7 PermissionDenied -- GrantDeviceControl sur un device inexistant",
            7,
            lambda: requests.post(
                f"{BASE_URL}/v1/devices/{uuid.uuid4()}/control-licenses",
                json={"grantee_user_public_id": second_public_id},
                headers=auth,
                timeout=10,
            ),
        ),
    ]

    print()
    for i, (description, expected_grpc_code, call) in enumerate(SCENARIOS, start=1):
        r = call()
        print(f"{i}. {description}")
        print(f"   -> HTTP {r.status_code} (result_code attendu : {expected_grpc_code})")

    print("\nL'écriture est asynchrone (goroutine côté serveur) : on laisse 1s avant de relire.")
    time.sleep(1)

    print_logs_since(conn, user_id, run_started_at)
    print("\nPour rejouer cette vue plus tard : make activity-logs")
    conn.close()


if __name__ == "__main__":
    main()
