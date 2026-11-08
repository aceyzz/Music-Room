"""Variante concurrente de test_granting.py::test_granting_the_same_scope_twice_conflicts,
qui n'envoie ses deux requêtes que l'une après l'autre -- ça prouve qu'un
deuxième appel après que le premier a déjà committé est refusé, mais pas que
l'index unique device_control_licenses_one_live_per_scope tient sous une
vraie concurrence (deux transactions qui arrivent en même temps, pas l'une
après l'autre). Contrairement à track_vote/test_concurrency.py et
playlist_editor/test_concurrency.py, ce n'est pas une exigence citée par le
sujet pour ce service précis (V.2.2) -- ce test exerce le même mécanisme
(contrainte unique + requêtes HTTP parallèles), pas une exigence mandatée."""

from concurrent.futures import ThreadPoolExecutor


def test_concurrent_grants_for_the_same_scope_land_exactly_once(
    make_user, make_friendship, register_device, grant_control, create_event
):
    """8 requêtes GrantDeviceControl identiques (même device, même ami, même
    événement) partent en parallèle. Sans un verrouillage correct
    côté serveur, une race sur l'index unique pourrait laisser passer plus
    d'une ligne active, ou faire remonter une erreur 500 brute au lieu d'un
    409 propre. Exactement une doit réussir, les 7 autres doivent échouer
    proprement en 409 -- jamais en 500, jamais plus d'une en 200."""
    owner = make_user()
    friend = make_user()
    make_friendship(owner, friend)
    _, body = register_device(owner)
    device_id = int(body["device"]["id"])

    _, event_body = create_event(owner, name="Same scope")
    event_id = int(event_body["event"]["id"])

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: grant_control(device_id, owner, friend, event_id=event_id), range(8)))

    statuses = [status for status, _ in results]
    assert statuses.count(200) == 1, statuses
    assert statuses.count(409) == 7, statuses


def test_concurrent_grants_for_different_grantees_all_land(
    make_user, make_friendship, register_device, grant_control, create_event
):
    """Variante avec des portées DIFFÉRENTES plutôt que la même : 8 amis
    distincts reçoivent chacun une délégation sur le même appareil, en
    parallèle. Rien ne doit se perdre ni se mélanger entre des lignes qui ne
    se contestent pas la même contrainte unique."""
    owner = make_user()
    friends = [make_user() for _ in range(8)]
    for friend in friends:
        make_friendship(owner, friend)
    _, body = register_device(owner)
    device_id = int(body["device"]["id"])

    _, event_body = create_event(owner, name="One event, eight friends")
    event_id = int(event_body["event"]["id"])

    with ThreadPoolExecutor(max_workers=len(friends)) as pool:
        results = list(pool.map(lambda f: grant_control(device_id, owner, f, event_id=event_id), friends))

    assert all(status == 200 for status, _ in results), results
