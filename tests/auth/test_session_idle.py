"""Fenêtre d'inactivité des sessions (docs/data-model.md §5,
internal/auth/authn). Une session inutilisée depuis APP_SESSION_IDLE_DAYS
(défaut 7 jours) est refusée même avant son expiration absolue, et
last_used_at n'est réécrit qu'au-delà d'une minute.

RequestEmailVerification sert de RPC authentifiée bon marché : sa réponse sur
un compte non vérifié est OK, et Unauthenticated si la session est refusée."""


def _set_last_used(db_conn, user_id: int, interval: str):
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE user_sessions SET last_used_at = NOW() - %s::interval WHERE user_id = %s",
            (interval, user_id),
        )


def _last_used_age_seconds(db_conn, user_id: int) -> float:
    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT EXTRACT(EPOCH FROM NOW() - last_used_at) FROM user_sessions WHERE user_id = %s",
            (user_id,),
        )
        return float(cur.fetchone()[0])


def test_an_idle_session_is_rejected(
    registered_session, user_id_by_email, request_email_verification, db_conn
):
    account, token = registered_session()
    _set_last_used(db_conn, user_id_by_email(account["email"]), "8 days")

    status, _ = request_email_verification(token)
    assert status == "Unauthenticated"


def test_a_recently_used_session_is_accepted_and_touched(
    registered_session, user_id_by_email, request_email_verification, clear_code_rate_limit, db_conn
):
    account, token = registered_session()
    user_id = user_id_by_email(account["email"])
    _set_last_used(db_conn, user_id, "6 days")
    clear_code_rate_limit(user_id)  # Register a déjà consommé le crédit de la minute.

    status, _ = request_email_verification(token)
    assert status == "OK"
    # glissée : last_used_at est revenu à maintenant
    assert _last_used_age_seconds(db_conn, user_id) < 60


def test_a_session_used_under_a_minute_ago_is_not_rewritten(
    registered_session, user_id_by_email, request_email_verification, clear_code_rate_limit, db_conn
):
    account, token = registered_session()
    user_id = user_id_by_email(account["email"])
    _set_last_used(db_conn, user_id, "30 seconds")
    clear_code_rate_limit(user_id)

    assert request_email_verification(token)[0] == "OK"
    assert _last_used_age_seconds(db_conn, user_id) >= 30
