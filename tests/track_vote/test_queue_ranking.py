"""La file est triée par nombre de votes puis par ordre d'arrivée à ce score ;
un même utilisateur ne peut compter deux fois sur la même entrée."""


def test_ranked_by_vote_count_then_suggestion_order(
    make_user, make_song, create_event, suggest, vote, get_queue
):
    """Le cœur du sujet V.2.1 : "if a track gets many votes, it goes up in
    the list and is played earlier". On suggère B puis C (C arrive après B),
    on donne 1 vote à B et 2 à C -> C doit passer devant B dans la file,
    malgré son arrivée plus tardive. C'est le classement par vote_count qui
    prime sur l'ordre de suggestion, pas l'inverse."""
    host = make_user()
    voter1 = make_user()
    voter2 = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])

    # Rien ne démarre tout seul (D3) : B et C restent tous deux en file,
    # sans morceau "de sacrifice".

    song_b = make_song()
    _, body = suggest(event_id, host, song_b)
    entry_b = next(e for e in body["queue"] if int(e["song"]["id"]) == song_b["id"])

    song_c = make_song()
    _, body = suggest(event_id, host, song_c)
    entry_c = next(e for e in body["queue"] if int(e["song"]["id"]) == song_c["id"])

    # B : 1 vote. C : 2 votes, alors qu'il a été suggéré après B.
    vote(event_id, int(entry_b["id"]), voter1)
    vote(event_id, int(entry_c["id"]), voter1)
    vote(event_id, int(entry_c["id"]), voter2)

    status, body = get_queue(event_id, host)
    assert status == 200
    queue = body["queue"]
    # C d'abord (2 votes), B ensuite (1 vote) -- l'ordre d'arrivée n'a compté
    # que pour départager un éventuel ex-æquo, qui n'a pas eu lieu ici.
    assert [int(e["song"]["id"]) for e in queue] == [song_c["id"], song_b["id"]]
    assert int(queue[0]["voteCount"]) == 2
    assert int(queue[1]["voteCount"]) == 1


def test_voting_twice_is_a_no_op(api, make_user, make_song, create_event, suggest, vote):
    """Un même utilisateur ne peut pas gonfler le score d'un morceau en
    votant plusieurs fois pour la même entrée : le second vote est accepté
    sans erreur (idempotent, un client qui rejoue la requête ne casse rien)
    mais n'incrémente pas le compteur -- `accepted` passe à False pour que
    le client sache que ce vote-là n'a rien changé."""
    host = make_user()
    voter = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    suggest(event_id, host, make_song())  # occupe "current", démarre la radio.
    _, body = suggest(event_id, host, make_song())
    entry_id = int(body["queue"][0]["id"])

    status, body = vote(event_id, entry_id, voter)
    assert status == 200 and body["accepted"] is True

    # Même utilisateur, même entrée, une deuxième fois.
    status, body = vote(event_id, entry_id, voter)
    assert status == 200 and body["accepted"] is False
    entry = next(e for e in body["queue"] if int(e["id"]) == entry_id)
    assert int(entry["voteCount"]) == 1  # toujours 1, pas 2.
