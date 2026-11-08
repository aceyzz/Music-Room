"""Exigence explicite du sujet : "You should especially care about the
management of competition problematics: for instance, if several people
vote for different tracks or the same one in a playlist." Ces deux tests
envoient de vrais votes HTTP en parallèle (pas de mock, pas de simulation) :
si l'UPDATE atomique côté serveur (CastQueueVote, contrainte UNIQUE +
ON CONFLICT DO NOTHING, cf. docs/data-model.md §10.2) avait une faille,
c'est une race qui se manifesterait ici, pas une lecture de code."""

from concurrent.futures import ThreadPoolExecutor


def test_concurrent_votes_on_the_same_song_all_land_exactly_once(
    make_user, make_song, create_event, suggest, vote, get_queue
):
    """10 utilisateurs différents votent pour LA MÊME entrée de file en même
    temps. Sans verrouillage correct côté serveur, des votes concurrents
    pourraient se marcher dessus (lost update classique : deux transactions
    lisent vote_count=5, incrémentent chacune à 6, une des deux écritures est
    perdue). Le compteur final doit être exactement égal au nombre de
    votants, ni plus (double comptage), ni moins (vote perdu)."""
    host = make_user()
    voters = [make_user() for _ in range(10)]
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    suggest(event_id, host, make_song())  # occupe "current".
    _, body = suggest(event_id, host, make_song())  # la cible des votes.
    entry_id = int(body["queue"][0]["id"])

    # Tous les votes partent en parallèle, dans des threads différents --
    # requests/ThreadPoolExecutor suffit ici car le travail est de l'I/O
    # (attente réseau), pas du calcul, donc le GIL de Python n'est pas un
    # obstacle à la vraie concurrence des requêtes HTTP.
    with ThreadPoolExecutor(max_workers=len(voters)) as pool:
        results = list(pool.map(lambda u: vote(event_id, entry_id, u), voters))

    assert all(status == 200 and body["accepted"] for status, body in results)

    status, body = get_queue(event_id, host)
    entry = next(e for e in body["queue"] if int(e["id"]) == entry_id)
    assert int(entry["voteCount"]) == len(voters)


def test_concurrent_votes_on_different_songs_all_land(
    make_user, make_song, create_event, suggest, vote, get_queue
):
    """Variante de la même exigence, mais avec des votes simultanés sur des
    ENTRÉES différentes plutôt que la même : ça exerce un chemin différent
    (verrous de lignes distinctes plutôt qu'une seule ligne contestée), et le
    sujet cite explicitement les deux cas ("different tracks or the same
    one"). Chaque votant vote pour "son" morceau ; à la fin, chacun doit
    avoir exactement 1 vote, aucun mélange entre les entrées."""
    host = make_user()
    voters = [make_user() for _ in range(8)]
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    suggest(event_id, host, make_song())  # occupies "current"

    # Un morceau en file par votant, pour que chaque vote parallèle touche
    # une ligne différente.
    entry_ids = []
    for _ in voters:
        _, body = suggest(event_id, host, make_song())
        entry_ids.append(int(body["queue"][-1]["id"]))

    with ThreadPoolExecutor(max_workers=len(voters)) as pool:
        results = list(
            pool.map(lambda pair: vote(event_id, pair[0], pair[1]), zip(entry_ids, voters))
        )

    assert all(status == 200 and body["accepted"] for status, body in results)

    status, body = get_queue(event_id, host)
    counts = {int(e["id"]): int(e["voteCount"]) for e in body["queue"]}
    assert all(counts[entry_id] == 1 for entry_id in entry_ids)
