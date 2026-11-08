"""V.1 : connexion par email/mot de passe. Login ne distingue jamais "email
inconnu" de "mauvais mot de passe" -- une seule erreur, pour ne pas révéler
quels emails ont un compte (login.ErrInvalidCredentials)."""

import pytest


def test_login_with_correct_credentials_returns_a_session(register, login, unique_account):
    account = unique_account()
    register(account["email"], account["password"], account["display_name"])

    status, body = login(account["email"], account["password"])
    assert status == "OK"
    assert body["sessionToken"]
    assert body["displayName"] == account["display_name"]
    assert body["email"] == account["email"]
    assert int(body["expiresAtUnix"]) > 0


def test_login_with_wrong_password_is_unauthenticated(register, login, unique_account):
    account = unique_account()
    register(account["email"], account["password"], account["display_name"])

    status, _ = login(account["email"], "not-the-password")
    assert status == "Unauthenticated"


def test_login_with_unknown_email_is_unauthenticated(login, unique_account):
    account = unique_account()
    status, _ = login(account["email"], account["password"])
    assert status == "Unauthenticated"


def test_two_logins_issue_different_session_tokens(register, login, unique_account):
    """Chaque connexion émet un nouveau token opaque -- pas de token
    réutilisé ou dérivé d'un secret partagé."""
    account = unique_account()
    register(account["email"], account["password"], account["display_name"])

    _, first = login(account["email"], account["password"])
    _, second = login(account["email"], account["password"])
    assert first["sessionToken"] != second["sessionToken"]


MAX_FAILURES_PER_IP = 20  # login.MaxFailuresPerIP


@pytest.fixture
def this_ip_clean(login, unique_account, db_conn):
    """L'adresse de ce conteneur vue par le backend, sans échec récent :
    lue sur un premier échec, effacée avant et après le test, pour que la
    limite par adresse ne bloque ni ce test ni la suite."""
    account = unique_account()
    login(account["email"], account["password"])
    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT host(ip_address) FROM login_attempts WHERE email = %s", (account["email"],)
        )
        (ip,) = cur.fetchone()
    assert ip, "le backend n'a pas enregistré l'adresse"

    def clear():
        with db_conn.cursor() as cur:
            cur.execute("DELETE FROM login_attempts WHERE ip_address = %s::inet", (ip,))

    clear()
    yield ip
    clear()


def test_too_many_failures_from_one_address_block_every_account(
    register, login, unique_account, this_ip_clean
):
    """La limite par email laisse une machine essayer un mot de passe sur
    tous les comptes : après MAX_FAILURES_PER_IP échecs depuis la même
    adresse, emails différents, même le bon mot de passe est refusé."""
    account = unique_account()
    register(account["email"], account["password"], account["display_name"])

    for _ in range(MAX_FAILURES_PER_IP):
        status, _ = login(unique_account()["email"], "not-the-password")
        assert status == "Unauthenticated"

    status, body = login(account["email"], account["password"])
    assert status == "ResourceExhausted", body


def test_a_forged_forwarded_address_does_not_lift_the_block(
    register, login, unique_account, this_ip_clean, api
):
    """Par REST, l'adresse est celle que la passerelle ajoute en dernier dans
    X-Forwarded-For : celle qu'envoie le client ne compte pas."""
    account = unique_account()
    register(account["email"], account["password"], account["display_name"])
    for _ in range(MAX_FAILURES_PER_IP):
        login(unique_account()["email"], "not-the-password")

    status, body = api.post(
        "/v1/auth/login",
        json={"email": account["email"], "password": account["password"]},
        headers={"X-Forwarded-For": "198.51.100.1"},
    )
    assert status == 429, body
