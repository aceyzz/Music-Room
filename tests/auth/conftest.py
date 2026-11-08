"""Helpers propres à AuthService (V.1 compte). Ces tests passent par
`grpcurl` en sous-processus plutôt que par le client `requests` partagé
(tests/conftest.py). grpcurl s'appuie sur la réflexion serveur
(grpc.reflection, activée dans cmd/main.go), donc aucun stub Python généré
n'est nécessaire.

Le statut renvoyé par ces fixtures est le NOM du code gRPC ("OK",
"InvalidArgument", "AlreadyExists"...), pas un entier HTTP -- comparer avec
`assert status == "OK"`, pas `== 200`."""

import hashlib
import json
import os
import secrets
import subprocess
import uuid

import pytest

GRPC_ADDR = os.environ.get("GRPC_ADDR", "localhost:50051")
DEFAULT_PASSWORD = "password1234"


class GrpcApi:
    """Petit client gRPC pour AuthService. `token`, quand fourni, part dans
    le header `authorization: Bearer <token>` (metadata gRPC), exactement
    comme Logout l'attend (internal/services/authctx.go:bearerToken)."""

    def __init__(self, addr: str):
        self.addr = addr

    def call(self, method: str, payload: dict, token: str | None = None):
        cmd = ["grpcurl", "-plaintext"]
        if token:
            cmd += ["-H", f"authorization: Bearer {token}"]
        cmd += ["-d", json.dumps(payload), self.addr, f"music_room.v1.AuthService/{method}"]

        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        if proc.returncode == 0:
            body = json.loads(proc.stdout) if proc.stdout.strip() else {}
            return "OK", body

        code, message = "Unknown", proc.stderr.strip()
        for line in proc.stderr.splitlines():
            line = line.strip()
            if line.startswith("Code:"):
                code = line[len("Code:") :].strip()
            elif line.startswith("Message:"):
                message = line[len("Message:") :].strip()
        return code, {"message": message}


@pytest.fixture(scope="session")
def grpc():
    return GrpcApi(GRPC_ADDR)


@pytest.fixture
def unique_account():
    """(email, password, display_name) prêts pour register(), uniques à
    chaque appel pour ne jamais entrer en collision avec un test voisin."""

    def _make(password: str = DEFAULT_PASSWORD) -> dict:
        suffix = uuid.uuid4().hex[:10]
        return {
            "email": f"auth-{suffix}@example.test",
            "password": password,
            "display_name": f"auth-{suffix}",
        }

    return _make


@pytest.fixture
def register(grpc, db_conn):
    """Register() via l'API réelle -- pas d'insertion directe, c'est
    exactement le chemin que ce dossier teste. Piste les emails créés pour
    le nettoyage : Register ne renvoie que public_id, jamais l'id interne."""
    created_emails = []

    def _register(email: str, password: str, display_name: str):
        status, body = grpc.call(
            "Register",
            {"email": email, "password": password, "display_name": display_name},
        )
        if status == "OK":
            created_emails.append(email)
        return status, body

    yield _register

    if created_emails:
        with db_conn.cursor() as cur:
            cur.execute("DELETE FROM users WHERE email = ANY(%s)", (created_emails,))


@pytest.fixture
def login(grpc):
    def _login(email: str, password: str):
        return grpc.call("Login", {"email": email, "password": password})

    return _login


@pytest.fixture
def logout(grpc):
    def _logout(session_token: str):
        return grpc.call("Logout", {}, token=session_token)

    return _logout


@pytest.fixture
def verify_email(grpc):
    """VerifyEmail est authentifié : un code ne vérifie que le compte de la
    session qui le présente."""

    def _verify(code: str, session_token: str | None):
        return grpc.call("VerifyEmail", {"code": code}, token=session_token)

    return _verify


@pytest.fixture
def request_email_verification(grpc):
    def _request(session_token: str | None):
        return grpc.call("RequestEmailVerification", {}, token=session_token)

    return _request


@pytest.fixture
def registered_session(register, login, unique_account):
    """Un compte neuf et sa session : (account, session_token)."""

    def _make():
        account = unique_account()
        status, _ = register(account["email"], account["password"], account["display_name"])
        assert status == "OK"
        status, body = login(account["email"], account["password"])
        assert status == "OK"
        return account, body["sessionToken"]

    return _make


@pytest.fixture
def user_id_by_email(db_conn):
    def _lookup(email: str) -> int:
        with db_conn.cursor() as cur:
            cur.execute("SELECT id FROM users WHERE email = %s", (email,))
            row = cur.fetchone()
            assert row is not None, f"no user with email {email}"
            return row[0]

    return _lookup


@pytest.fixture
def issue_email_verification_code(db_conn):
    """Insère directement un user_tokens (purpose='email_verification') : le
    code envoyé par Register ou RequestEmailVerification ne part que par
    mail, donc le test en pose un qu'il connaît. Invalide d'abord les codes
    en attente, comme token.Repository.Issue. token_hash est un simple
    SHA-256 du code (security.HashSessionToken, db/query/user_tokens.sql),
    reproductible ici sans dépendre du générateur Go."""

    def _issue(user_id: int, expires_in_minutes: int = 15) -> str:
        code = f"{secrets.randbelow(10**6):06d}"
        token_hash = hashlib.sha256(code.encode()).digest()
        with db_conn.cursor() as cur:
            cur.execute(
                """
                UPDATE user_tokens SET consumed_at = NOW()
                WHERE user_id = %s AND purpose = 'email_verification'
                  AND consumed_at IS NULL
                """,
                (user_id,),
            )
            cur.execute(
                """
                INSERT INTO user_tokens (user_id, purpose, token_hash, expires_at)
                VALUES (%s, 'email_verification', %s, NOW() + make_interval(mins => %s))
                """,
                (user_id, token_hash, expires_in_minutes),
            )
        return code

    return _issue


@pytest.fixture
def clear_code_rate_limit(db_conn):
    """Register envoie déjà un code de vérification à l'inscription
    (internal/services/auth_service.go:Register, `s.emailVerif.RequestCode`).
    Depuis PR #26 (`feat/auth-rate-limits`), un deuxième code pour le même
    user_id dans la minute qui suit est refusé en `ResourceExhausted`
    (`onetimecode.ShortWindowMax`) -- ce qui bloque tout test qui part de
    `registered_session()` puis appelle `request_email_verification`
    lui-même, pour une raison sans rapport avec ce qu'il vérifie. Recule le
    code envoyé par Register largement hors des deux fenêtres (`ShortWindow`
    1 min, `LongWindow` 1h) pour que l'appel explicite du test reparte comme
    si c'était le premier."""

    def _clear(user_id: int):
        with db_conn.cursor() as cur:
            cur.execute(
                "UPDATE user_tokens SET created_at = NOW() - INTERVAL '2 hours' "
                "WHERE user_id = %s AND purpose = 'email_verification'",
                (user_id,),
            )

    return _clear
