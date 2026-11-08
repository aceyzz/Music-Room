"""V.1 : "the user must be able to create an account". Register(email,
password, display_name) crée un compte email/mot de passe classique."""


def test_register_creates_an_account(register, unique_account):
    account = unique_account()
    status, body = register(account["email"], account["password"], account["display_name"])
    assert status == "OK"
    assert body["displayName"] == account["display_name"]
    assert body["email"] == account["email"]
    assert body["userPublicId"]


def test_register_rejects_a_duplicate_email(register, unique_account):
    account = unique_account()
    assert register(account["email"], account["password"], account["display_name"])[0] == "OK"

    status, _ = register(account["email"], account["password"], "someone-else")
    assert status == "AlreadyExists"


def test_register_rejects_a_duplicate_display_name(register, unique_account):
    """display_name est UNIQUE (docs/data-model.md §5) : deux comptes ne
    peuvent pas partager le même pseudo, même avec des emails différents."""
    account = unique_account()
    assert register(account["email"], account["password"], account["display_name"])[0] == "OK"

    other_email = f"other-{account['email']}"
    status, _ = register(other_email, account["password"], account["display_name"])
    assert status == "AlreadyExists"


def test_register_rejects_a_password_below_the_minimum_length(register, unique_account):
    """APP_MIN_PASSWORD_LENGTH plancher à 8 (register.DefaultMinPasswordLen).
    Les erreurs de validation de Register ressortent en InvalidArgument
    (toGRPCError), pour que le client puisse les afficher."""
    account = unique_account(password="short")
    status, _ = register(account["email"], account["password"], account["display_name"])
    assert status == "InvalidArgument"


def test_register_rejects_an_invalid_email(register, unique_account):
    account = unique_account()
    status, _ = register("not-an-email", account["password"], account["display_name"])
    assert status == "InvalidArgument"
