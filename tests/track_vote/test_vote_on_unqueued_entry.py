"""Un vote pour un morceau qui n'est plus en file (il joue déjà, ou il a été
joué) est refusé (accepted=false) -- et ne doit RIEN écrire. La requête
CastQueueVote insérait autrefois la ligne de vote sans condition, dans un CTE,
alors que le compteur ne bougeait que pour une entrée encore 'queued' : la ligne
restait, vote_count non, et les deux divergeaient. Trouvé par le contrôle de
cohérence du test de charge (docs/load-testing.md), où des votes tombent sur le
morceau que l'hôte vient de lancer."""


def _vote_rows(db_conn, entry_id):
    with db_conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM event_queue_votes WHERE queue_entry_id = %s", (entry_id,))
        return cur.fetchone()[0]


def _vote_count(db_conn, entry_id):
    with db_conn.cursor() as cur:
        cur.execute("SELECT vote_count FROM event_queue_entries WHERE id = %s", (entry_id,))
        return cur.fetchone()[0]


def test_vote_for_a_playing_song_is_refused_and_leaves_no_row(
    make_user, make_song, create_event, suggest, play_next, vote, db_conn
):
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    suggest(event_id, host, make_song())  # joue tout de suite (radio silencieuse)
    _, body = suggest(event_id, host, make_song())  # reste en file
    entry_id = int(body["queue"][0]["id"])

    # L'hôte passe au suivant : l'entrée qu'on vise devient "playing".
    status, _ = play_next(event_id, host)
    assert status == 200

    status, body = vote(event_id, entry_id, host)
    assert status == 200
    assert body["accepted"] is False
    assert _vote_rows(db_conn, entry_id) == 0
    assert _vote_count(db_conn, entry_id) == 0


def test_vote_for_a_queued_song_still_lands(
    make_user, make_song, create_event, suggest, vote, db_conn
):
    """Le pendant positif : le vote normal écrit toujours sa ligne ET le compteur."""
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    suggest(event_id, host, make_song())
    _, body = suggest(event_id, host, make_song())
    entry_id = int(body["queue"][0]["id"])

    status, body = vote(event_id, entry_id, host)
    assert status == 200
    assert body["accepted"] is True
    assert _vote_rows(db_conn, entry_id) == 1
    assert _vote_count(db_conn, entry_id) == 1
