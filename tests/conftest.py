"""Fixtures partagées pour la suite de tests API (boîte noire, REST/JSON via
grpc-gateway) de Music Room.

Ces tests supposent la stack lancée (`make api-test-up` ou `make api-test`) :
postgres + redis + backend, backend joignable en REST sur API_BASE_URL et
postgres joignable sur TEST_DATABASE_URL.

Pas d'appel à AuthService : les utilisateurs et morceaux de test sont insérés
directement en base (voir make_user), ce qui évite aussi tout appel réseau
vers la vraie API Deezer pendant les tests. make_user insère aussi une
session valide, pour authentifier les requêtes (voir public_id_of et
auth_headers) -- l'intercepteur de permissions (backend/internal/
interceptor/) refuse désormais toute requête non authentifiée.

Note sur le JSON : les champs int64 (id, host_id, vote_count...) reviennent
sous forme de chaînes ("1", pas 1) -- c'est protojson, pas un bug. `int(...)`
suffit à les comparer ; les int32/bool/string restent natifs.
"""

import hashlib
import itertools
import os
import secrets
import time
import uuid

import psycopg2
import pytest
import requests

BASE_URL = os.environ.get("API_BASE_URL", "http://localhost:8081")
DB_DSN = os.environ["TEST_DATABASE_URL"]
OPENFGA_URL = os.environ.get("OPENFGA_API_URL", "http://localhost:8082")
OPENFGA_STORE_ID = os.environ.get("OPENFGA_STORE_ID", "01MRAVTHZ00000000000000000")


def fga_write(writes=None, deletes=None):
    """Écrit/supprime des tuples OpenFGA directement, en contournant l'outbox
    (backend/internal/authz/outbox) -- nécessaire pour tout ce que les
    fixtures de ce fichier créent en SQL direct (make_user), puisque rien
    n'enqueue alors la tuple que le vrai chemin applicatif aurait écrite. Voir
    backend/internal/authz/tuple.go:NewUser pour la liste canonique des
    tuples qu'un compte a besoin dès sa création."""
    body = {}
    if writes:
        body["writes"] = {"tuple_keys": writes}
    if deletes:
        body["deletes"] = {"tuple_keys": deletes}
    if not body:
        return
    r = requests.post(f"{OPENFGA_URL}/stores/{OPENFGA_STORE_ID}/write", json=body, timeout=10)
    r.raise_for_status()


def unique_suffix() -> str:
    return uuid.uuid4().hex[:10]


class Api:
    """Petit client HTTP pour la passerelle REST/JSON de grpc-gateway."""

    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")

    def _body(self, response: requests.Response):
        if not response.content:
            return {}
        return response.json()

    def get(self, path: str, headers=None, **params):
        r = requests.get(f"{self.base_url}{path}", params=params, headers=headers, timeout=10)
        return r.status_code, self._body(r)

    def post(self, path: str, json=None, headers=None):
        r = requests.post(f"{self.base_url}{path}", json=json or {}, headers=headers, timeout=10)
        return r.status_code, self._body(r)

    def patch(self, path: str, json=None, headers=None):
        r = requests.patch(f"{self.base_url}{path}", json=json or {}, headers=headers, timeout=10)
        return r.status_code, self._body(r)

    def put(self, path: str, json=None, headers=None):
        r = requests.put(f"{self.base_url}{path}", json=json or {}, headers=headers, timeout=10)
        return r.status_code, self._body(r)

    def delete(self, path: str, headers=None):
        r = requests.delete(f"{self.base_url}{path}", headers=headers, timeout=10)
        return r.status_code, self._body(r)


def _wait_for_backend():
    deadline = time.time() + 30
    last_error = None
    while time.time() < deadline:
        try:
            # N'importe quelle route répond (même 404/400) : on veut juste
            # savoir que le gateway HTTP écoute.
            requests.get(f"{BASE_URL}/v1/events/0", timeout=2)
            return
        except requests.RequestException as exc:
            last_error = exc
            time.sleep(0.5)
    raise RuntimeError(f"backend injoignable sur {BASE_URL}: {last_error}")


@pytest.fixture(scope="session", autouse=True)
def _backend_ready():
    _wait_for_backend()


@pytest.fixture(scope="session")
def db_conn():
    conn = psycopg2.connect(DB_DSN)
    conn.autocommit = True
    yield conn
    conn.close()


@pytest.fixture
def api():
    return Api(BASE_URL)


@pytest.fixture
def make_user(db_conn):
    """Insère un utilisateur directement en base (pas d'AuthService en REST,
    et de toute façon pas besoin d'un vrai mot de passe pour ces tests) --
    ainsi qu'une session déjà valide, pour que l'appelant puisse
    immédiatement authentifier des requêtes en son nom (voir
    `public_id_of`/`auth_headers` ci-dessous).

    La session est insérée directement en base plutôt que via
    POST /v1/auth/login, par le même principe que
    tests/auth/conftest.py:issue_email_verification_code pour les codes de
    vérification : security.HashSessionToken (backend/internal/security/
    token.go) est un sha256 sans sel du token en clair, donc reproductible
    ici sans repasser par le vrai flux d'auth ni un mot de passe.

    Le retour reste l'id interne (int), inchangé, pour ne pas casser les
    appelants qui l'utilisent avec make_friendship ou des assertions SQL
    directes."""
    created_ids = []
    sessions = {}  # user_id -> (public_id, plain session token)

    def _make(display_name: str | None = None) -> int:
        display_name = display_name or f"test-{unique_suffix()}"
        email = f"{display_name}@example.test"
        with db_conn.cursor() as cur:
            cur.execute(
                "INSERT INTO users (display_name, email) VALUES (%s, %s) RETURNING id, public_id",
                (display_name, email),
            )
            user_id, public_id = cur.fetchone()

            token = secrets.token_urlsafe(32)
            token_hash = hashlib.sha256(token.encode()).digest()
            cur.execute(
                """
                INSERT INTO user_sessions (user_id, token_hash, expires_at)
                VALUES (%s, %s, NOW() + INTERVAL '1 day')
                """,
                (user_id, token_hash),
            )
        public_id = str(public_id)
        # account_owner + anyone : les deux tuples qu'un compte a dès sa
        # création (NewUser côté Go) et sans lesquelles même le propriétaire
        # ne peut rien faire sur son propre compte -- voir fga_write ci-dessus.
        fga_write(writes=[
            {"user": f"user:{public_id}", "relation": "account_owner", "object": f"user:{public_id}"},
            {"user": "user:*", "relation": "anyone", "object": f"user:{public_id}"},
        ])
        created_ids.append(user_id)
        sessions[user_id] = (public_id, token)
        return user_id

    _make.sessions = sessions
    yield _make

    if created_ids:
        # Cascade sur events/playlists/devices/friendships/memberships/
        # sessions créés par ces utilisateurs (toutes les FK pertinentes sont
        # ON DELETE CASCADE depuis users.id).
        with db_conn.cursor() as cur:
            cur.execute("DELETE FROM users WHERE id = ANY(%s)", (created_ids,))
        fga_write(deletes=[
            {"user": f"user:{public_id}", "relation": "account_owner", "object": f"user:{public_id}"}
            for public_id, _ in sessions.values()
        ] + [
            {"user": "user:*", "relation": "anyone", "object": f"user:{public_id}"}
            for public_id, _ in sessions.values()
        ])


@pytest.fixture
def public_id_of(make_user):
    """UUID public d'un utilisateur créé par make_user -- ce que l'API attend
    désormais dans les champs `*_public_id` des requêtes."""

    def _public_id(user_id: int) -> str:
        return make_user.sessions[user_id][0]

    return _public_id


@pytest.fixture
def auth_headers(make_user):
    """Header Authorization prêt à passer à Api.get/post/patch/put/delete
    pour agir en tant que ce user_id (voir make_user)."""

    def _headers(user_id: int) -> dict:
        return {"Authorization": f"Bearer {make_user.sessions[user_id][1]}"}

    return _headers


_song_seq = itertools.count()


@pytest.fixture
def make_song(db_conn):
    """Insère un morceau directement dans le cache Deezer (songs), pour que
    SuggestSong/AddSongToPlaylist le trouvent sans jamais appeler la vraie API
    Deezer. deezer_song_id est un identifiant pseudo-aléatoire pour rester
    valide même si le volume postgres n'est pas repartie de zéro entre deux
    exécutions de la suite."""

    def _make(title: str | None = None, duration_seconds: int = 180) -> dict:
        deezer_song_id = (uuid.uuid4().int % 800_000_000) + 100_000_000 + next(_song_seq)
        title = title or f"song-{unique_suffix()}"
        with db_conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO songs (deezer_song_id, title, duration_seconds, artist_name)
                VALUES (%s, %s, %s, %s)
                RETURNING id
                """,
                (deezer_song_id, title, duration_seconds, "Test Artist"),
            )
            song_id = cur.fetchone()[0]
        return {"id": song_id, "deezer_song_id": deezer_song_id}

    return _make


# 1x1 transparent PNG, valid enough for image-service (image::load_from_memory)
# to accept and resize -- pixel content doesn't matter for these tests. Shared
# by tests/user (avatar) and tests/playlist_editor (cover).
TINY_PNG_BASE64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk"
    "+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


@pytest.fixture
def tiny_png_base64():
    return TINY_PNG_BASE64


@pytest.fixture
def fetch_media(api):
    """GET direct sur /media/<storage_key> -- pas de JSON ici (fichier
    binaire), donc en dehors du client Api."""

    def _fetch(storage_key):
        r = requests.get(f"{api.base_url}/media/{storage_key}", timeout=10)
        return r.status_code, r.content

    return _fetch


@pytest.fixture
def eventually():
    """Réessaie `call()` jusqu'à ce que `predicate(status, body)` soit vrai ou
    que `timeout` s'écoule, et renvoie le dernier essai.

    Nécessaire pour toute assertion qui dépend d'un effet passé par l'API
    réelle (block, invite, grant de contrôle...) qui écrit une tuple OpenFGA
    via l'outbox asynchrone (APP_OPENFGA_SYNC_INTERVAL_SECONDS, 1s dans
    docker-compose.yaml pour ces tests) plutôt que par insertion SQL directe
    -- une assertion immédiate après l'appel court-circuiterait le worker,
    pas seulement le cas testé. Le timeout par défaut (2s) laisse largement
    de marge au-dessus de l'intervalle configuré ; si ça n'a toujours pas
    convergé à l'échéance, le dernier essai renvoyé fait échouer l'assertion
    normalement plutôt que de masquer un vrai bug derrière un retry sans fin."""

    def _eventually(call, predicate, timeout=2.0, interval=0.05):
        deadline = time.time() + timeout
        result = call()
        while not predicate(*result) and time.time() < deadline:
            time.sleep(interval)
            result = call()
        return result

    return _eventually


@pytest.fixture
def make_friendship(db_conn):
    """Insère directement une ligne friendships, sans passer par le flux
    demande/acceptation de UserService (voir tests/user/conftest.py:befriend
    pour l'exercer via l'API) -- pratique quand un test d'un AUTRE service
    (delegation, playlist, event) veut juste "deux amis" comme donnée de
    départ, sans que l'amitié elle-même soit ce qui est testé."""

    def _make(user_a: int, user_b: int) -> None:
        with db_conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO friendships (user_a_id, user_b_id)
                VALUES (LEAST(%s, %s), GREATEST(%s, %s))
                ON CONFLICT DO NOTHING
                """,
                (user_a, user_b, user_a, user_b),
            )

    return _make
