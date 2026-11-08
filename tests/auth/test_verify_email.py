"""V.1 : "the application must demand a mail validation".

Register envoie le premier code, RequestEmailVerification en renvoie un, et
VerifyEmail(code) le consomme et marque l'email vérifié. Les deux dernières
sont authentifiées : l'adresse et le compte viennent de la session, jamais de
la requête.

Le code ne part que par mail : ces tests posent donc un token qu'ils
connaissent directement en base via issue_email_verification_code."""


def test_verify_email_with_a_valid_code_succeeds(
    registered_session, user_id_by_email, issue_email_verification_code, verify_email, login
):
    account, token = registered_session()
    code = issue_email_verification_code(user_id_by_email(account["email"]))

    status, _ = verify_email(code, token)
    assert status == "OK"

    # Login le renvoie : c'est ce que lit le client pour lever l'écran de
    # vérification.
    status, body = login(account["email"], account["password"])
    assert status == "OK"
    assert body.get("emailVerified") is True


def test_login_reports_an_unverified_email(registered_session, login):
    account, _ = registered_session()

    status, body = login(account["email"], account["password"])
    assert status == "OK"
    # protojson omet un bool à false
    assert body.get("emailVerified", False) is False


def test_verify_email_requires_a_session(
    registered_session, user_id_by_email, issue_email_verification_code, verify_email
):
    account, _ = registered_session()
    code = issue_email_verification_code(user_id_by_email(account["email"]))

    status, _ = verify_email(code, None)
    assert status == "Unauthenticated"


def test_verify_email_with_another_accounts_code_is_invalid_argument(
    registered_session, user_id_by_email, issue_email_verification_code, verify_email
):
    """Un code valide présenté par une autre session se comporte comme un
    code inconnu : sinon deviner 6 chiffres suffirait à vérifier le compte
    de quelqu'un d'autre."""
    victim, _ = registered_session()
    _, attacker_token = registered_session()
    code = issue_email_verification_code(user_id_by_email(victim["email"]))

    status, _ = verify_email(code, attacker_token)
    assert status == "InvalidArgument"


def test_verify_email_with_an_unknown_code_is_invalid_argument(registered_session, verify_email):
    _, token = registered_session()

    status, _ = verify_email("000000", token)
    assert status == "InvalidArgument"


def test_verify_email_with_an_already_consumed_code_is_failed_precondition(
    registered_session, user_id_by_email, issue_email_verification_code, verify_email
):
    """Même code, deuxième appel : ce n'est PAS traité comme un code inconnu
    (InvalidArgument) mais comme un compte déjà vérifié (FailedPrecondition)
    -- même résultat que test_verify_email_when_already_verified_is_failed_precondition,
    et c'est normal : Service.Verify (emailverif/service.go) regarde
    d'abord si le compte est déjà vérifié, avant même de regarder le code.
    Une fois qu'un compte a été vérifié par CE code, il n'existe donc aucun
    moyen d'atteindre "code consommé mais compte pas encore vérifié" en le
    rejouant -- le court-circuit "déjà vérifié" prime toujours."""
    account, token = registered_session()
    code = issue_email_verification_code(user_id_by_email(account["email"]))
    assert verify_email(code, token)[0] == "OK"

    status, _ = verify_email(code, token)
    assert status == "FailedPrecondition"


def test_verify_email_with_an_expired_code_is_invalid_argument(
    registered_session, user_id_by_email, issue_email_verification_code, verify_email
):
    account, token = registered_session()
    code = issue_email_verification_code(
        user_id_by_email(account["email"]), expires_in_minutes=-1
    )

    status, _ = verify_email(code, token)
    assert status == "InvalidArgument"


def test_verify_email_when_already_verified_is_failed_precondition(
    registered_session, user_id_by_email, issue_email_verification_code, verify_email
):
    """Un deuxième code valide pour un compte déjà vérifié doit remonter une
    erreur distincte (FailedPrecondition, emailverif.ErrAlreadyVerified) --
    pas le même InvalidArgument qu'un code inconnu/expiré/consommé."""
    account, token = registered_session()
    user_id = user_id_by_email(account["email"])
    assert verify_email(issue_email_verification_code(user_id), token)[0] == "OK"

    status, _ = verify_email(issue_email_verification_code(user_id), token)
    assert status == "FailedPrecondition"


def test_register_issues_a_verification_code(registered_session, user_id_by_email, db_conn):
    account, _ = registered_session()
    user_id = user_id_by_email(account["email"])

    with db_conn.cursor() as cur:
        cur.execute(
            """
            SELECT COUNT(*) FROM user_tokens
            WHERE user_id = %s AND purpose = 'email_verification'
              AND consumed_at IS NULL AND expires_at > NOW()
            """,
            (user_id,),
        )
        assert cur.fetchone()[0] == 1


def test_request_email_verification_requires_a_session(request_email_verification):
    status, _ = request_email_verification(None)
    assert status == "Unauthenticated"


def test_request_email_verification_replaces_the_pending_code(
    registered_session, user_id_by_email, request_email_verification, clear_code_rate_limit, db_conn
):
    """Un renvoi invalide le code précédent (token.Repository.Issue) : un
    seul code utilisable à la fois."""
    account, token = registered_session()
    user_id = user_id_by_email(account["email"])
    clear_code_rate_limit(user_id)  # Register a déjà consommé le crédit de la minute.

    status, _ = request_email_verification(token)
    assert status == "OK"

    with db_conn.cursor() as cur:
        cur.execute(
            """
            SELECT COUNT(*) FILTER (WHERE consumed_at IS NULL),
                   COUNT(*)
            FROM user_tokens
            WHERE user_id = %s AND purpose = 'email_verification'
            """,
            (user_id,),
        )
        pending, total = cur.fetchone()
    assert (pending, total) == (1, 2)


def test_request_email_verification_when_already_verified_is_failed_precondition(
    registered_session,
    user_id_by_email,
    issue_email_verification_code,
    verify_email,
    request_email_verification,
):
    account, token = registered_session()
    code = issue_email_verification_code(user_id_by_email(account["email"]))
    assert verify_email(code, token)[0] == "OK"

    status, _ = request_email_verification(token)
    assert status == "FailedPrecondition"
