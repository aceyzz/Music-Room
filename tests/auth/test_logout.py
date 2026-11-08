"""Logout révoque la session portant le token passé en métadonnée gRPC
("authorization: Bearer <token>", internal/services/authctx.go), jamais
dans le corps du message."""


def test_logout_revokes_the_session(register, login, logout, unique_account):
    account = unique_account()
    register(account["email"], account["password"], account["display_name"])
    _, session = login(account["email"], account["password"])
    token = session["sessionToken"]

    status, _ = logout(token)
    assert status == "OK"


def test_logout_without_a_token_is_unauthenticated(logout):
    status, body = logout(None)
    assert status == "Unauthenticated"
    assert "missing session token" in body["message"]


def test_logout_with_an_unknown_token_is_a_silent_success(logout):
    """token inconnu ou déjà révoqué : succès silencieux -- répondre
    autrement dirait à l'appelant quels tokens existent (commentaire de
    logout.Service.Logout)."""
    status, _ = logout("this-token-was-never-issued")
    assert status == "OK"


def test_logout_can_be_called_twice_with_the_same_token(register, login, logout, unique_account):
    account = unique_account()
    register(account["email"], account["password"], account["display_name"])
    _, session = login(account["email"], account["password"])
    token = session["sessionToken"]

    assert logout(token)[0] == "OK"
    status, _ = logout(token)
    assert status == "OK"
