"""V.2.1 : par défaut tout le monde peut voter ; avec "invited_only" seuls
les invités le peuvent ; avec "location_time" il faut être dans le rayon du
lieu ET dans le créneau horaire quotidien. Aussi modifiable après création,
hôte uniquement (SetEventVoteLicense)."""

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

VENUE_TZ = "Europe/Paris"
PARIS = (48.8566, 2.3522)  # lat, lon du lieu de l'événement dans les tests location_time.
MADRID = (40.4168, -3.7038)  # à ~1000km de Paris : sert à simuler un vote "trop loin".


def _window_excluding_now(tz_name: str) -> tuple[str, str]:
    """Calcule un créneau d'une heure ("HH:MM", "HH:MM") garanti sans l'heure
    actuelle dedans, pour tester le refus "hors créneau" de façon
    déterministe (peu importe quand la suite tourne).

    On ne peut pas juste écrire un créneau fixe genre "02:00"-"03:00" : si les
    tests tournent pile à ce moment-là (CI de nuit, fuseau horaire du
    conteneur...), le test deviendrait vrai par accident. On décale donc de
    3h par rapport à "maintenant", dans un sens qui ne traverse jamais minuit
    (sinon la logique de comparaison d'heures se complique pour rien).
    """
    now = datetime.now(ZoneInfo(tz_name))
    if now.hour < 20:
        start = now + timedelta(hours=3)  # en avant : ne dépasse jamais 23h.
    else:
        start = now - timedelta(hours=3)  # après 20h, on recule plutôt.
    end = start + timedelta(hours=1)
    return start.strftime("%H:%M"), end.strftime("%H:%M")


def _window_crossing_midnight(tz_name: str) -> tuple[str, str]:
    """Fenêtre "HH:MM"-"HH:MM" qui CONTIENT "maintenant", construite pour que
    window_start > window_end -- la branche "traverse minuit" de
    within_vote_window (authz/model.fga), distincte de _window_excluding_now
    ci-dessus qui ne teste que des fenêtres "normales" (start <= end).
    N'importe quelle paire avec start > end déclenche cette branche côté
    serveur, pas seulement une fenêtre proche de minuit réel : end = +1h,
    start = +2h par rapport à "maintenant" suffit, "maintenant" tombant
    avant `end`.

    Robuste quelle que soit l'heure actuelle, y compris quand +1h ou +2h
    dépasse minuit : dans cette zone étroite (~1h/jour, juste avant minuit),
    le serveur reclasse la paire en fenêtre "normale" plutôt que "wrap" --
    le résultat (accepté) reste correct, seule la branche exercée change.
    Pas la peine d'éviter cette zone comme _window_excluding_now le fait
    pour la sienne : ici les DEUX issues (branche normale ou wrap) sont
    correctes, alors que là-bas une seule direction l'était."""
    now = datetime.now(ZoneInfo(tz_name))
    end = now + timedelta(hours=1)
    start = now + timedelta(hours=2)
    return start.strftime("%H:%M"), end.strftime("%H:%M")


def _window_crossing_midnight_excluding_now(tz_name: str) -> tuple[str, str]:
    """Variante de _window_crossing_midnight qui EXCLUT "maintenant" au lieu
    de l'inclure : end = -1h, start = +1h, donc "maintenant" tombe dans la
    bande refusée [end, start) -- même robustesse près de minuit réel."""
    now = datetime.now(ZoneInfo(tz_name))
    end = now - timedelta(hours=1)
    start = now + timedelta(hours=1)
    return start.strftime("%H:%M"), end.strftime("%H:%M")


def test_invited_only_restricts_voting_not_visibility(
    make_user, make_song, create_event, suggest, vote, get_event, invite_to_event, eventually
):
    """"invited_only" est une restriction sur le VOTE, pas sur la visibilité
    de l'événement : contrairement à un event `visibility=private`, un event
    public avec cette licence reste trouvable par tout le monde -- seul le
    droit de voter est réservé aux membres invités. C'est une distinction
    facile à rater en lisant juste le sujet ("with the right license, the
    invited people are the only one who can vote"), d'où ce test dédié."""
    host = make_user()
    member = make_user()
    outsider = make_user()
    _, body = create_event(host, vote_license="invited_only")
    event_id = int(body["event"]["id"])
    status, _ = invite_to_event(event_id, host, member)
    assert status == 200

    # Le premier morceau suggéré démarre tout seul la radio (event
    # silencieux) ; le second reste dans la file d'attente, c'est sur lui
    # qu'on va faire porter les votes.
    suggest(event_id, host, make_song())
    _, body = suggest(event_id, host, make_song())
    entry_id = int(body["queue"][0]["id"])

    # Public event (default visibility): the outsider can still see it...
    assert get_event(event_id, outsider)[0] == 200
    # ...but invited_only means only a member may vote.
    status, _ = vote(event_id, entry_id, outsider)
    assert status == 403

    # La tuple `member` de l'invitation passe par l'outbox (asynchrone, voir
    # tests/conftest.py:eventually).
    status, body = eventually(
        lambda: vote(event_id, entry_id, member), lambda status, _: status == 200
    )
    assert status == 200 and body["accepted"] is True


def test_location_time_enforces_venue_radius(make_user, make_song, create_event, suggest, vote):
    """Volet "lieu" de la licence location_time : même avec un créneau
    horaire qui couvre toute la journée (00:00-23:59, donc jamais la cause du
    refus ici), un vote envoyé depuis des coordonnées trop loin du lieu doit
    être refusé -- distance calculée côté serveur (formule de Haversine)."""
    host = make_user()
    nearby = make_user()
    far_away = make_user()
    _, body = create_event(
        host,
        vote_license="location_time",
        venue_latitude=PARIS[0],
        venue_longitude=PARIS[1],
        venue_radius_meters=200,  # 200m autour du lieu : Madrid en est très loin, Paris y est.
        vote_window_start="00:00",
        vote_window_end="23:59",
        vote_window_timezone=VENUE_TZ,
    )
    event_id = int(body["event"]["id"])
    # SuggestSong est gatée par la même licence que le vote (voir le
    # commentaire de suggester_latitude/longitude dans event_service.proto) :
    # même l'hôte doit suggérer depuis le lieu sous location_time, sans quoi
    # la suggestion elle-même est refusée (403) avant même d'atteindre la
    # question qu'on veut tester ici.
    suggest(event_id, host, make_song(), *PARIS)
    _, body = suggest(event_id, host, make_song(), *PARIS)
    entry_id = int(body["queue"][0]["id"])

    # Vote envoyé depuis Madrid : bien en dehors du rayon de 200m -> refusé.
    status, _ = vote(event_id, entry_id, far_away, *MADRID)
    assert status == 403

    # Même coordonnées que le lieu : accepté.
    status, body = vote(event_id, entry_id, nearby, *PARIS)
    assert status == 200 and body["accepted"] is True


def test_location_time_enforces_daily_window(
    make_user, make_song, create_event, suggest, vote, set_vote_license
):
    """Volet "créneau horaire" de la licence location_time : cette fois le
    votant est physiquement au bon endroit (mêmes coordonnées que le lieu),
    mais le créneau autorisé du jour ne couvre pas l'heure actuelle -> refusé
    quand même. Isole ce cas de celui du rayon (test précédent) pour que
    l'échec pointe sans ambiguïté vers la bonne règle.

    can_suggest_song == can_vote (model.fga) : sous location_time, suggérer
    est donc TOUT AUTANT gaté par la fenêtre horaire que voter -- avec une
    fenêtre qui exclut "maintenant" dès la création, personne ne pourrait
    jamais suggérer le morceau à voter. On crée donc l'event en "everyone"
    (créneau non pertinent), on suggère normalement, PUIS on bascule sur
    location_time avec le créneau excluant -- ce qui isole bien la question
    testée (voter hors créneau) de celle déjà couverte par l'autre test
    (suggérer hors du lieu)."""
    host = make_user()
    voter = make_user()
    start, end = _window_excluding_now(VENUE_TZ)
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    suggest(event_id, host, make_song())
    _, body = suggest(event_id, host, make_song())
    entry_id = int(body["queue"][0]["id"])

    status, _ = set_vote_license(
        event_id,
        host,
        vote_license="location_time",
        venue_latitude=PARIS[0],
        venue_longitude=PARIS[1],
        venue_radius_meters=200,
        vote_window_start=start,
        vote_window_end=end,
        vote_window_timezone=VENUE_TZ,
    )
    assert status == 200

    # Right at the venue, but outside today's vote window: still denied.
    status, _ = vote(event_id, entry_id, voter, *PARIS)
    assert status == 403


def test_location_time_wrap_window_accepts_a_vote_inside_it(
    make_user, make_song, create_event, suggest, vote, set_vote_license
):
    """within_vote_window (authz/model.fga) a une branche dédiée à une
    fenêtre qui traverse minuit (window_start > window_end, ex.
    22:00-02:00), distincte des deux tests location_time ci-dessus qui ne
    couvrent que des fenêtres "normales" (start <= end) -- c'est
    explicitement le cas que le commentaire du modèle appelle "le plus
    subtil" et met en garde de ne pas simplifier. Même flux que les tests
    location_time précédents : on crée en "everyone" (le créneau ne compte
    pas encore pour suggérer), on suggère, PUIS on bascule sur
    location_time avec une fenêtre qui traverse minuit et contient
    "maintenant"."""
    host = make_user()
    voter = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    suggest(event_id, host, make_song())
    _, body = suggest(event_id, host, make_song())
    entry_id = int(body["queue"][0]["id"])

    start, end = _window_crossing_midnight(VENUE_TZ)
    status, _ = set_vote_license(
        event_id,
        host,
        vote_license="location_time",
        venue_latitude=PARIS[0],
        venue_longitude=PARIS[1],
        venue_radius_meters=200,
        vote_window_start=start,
        vote_window_end=end,
        vote_window_timezone=VENUE_TZ,
    )
    assert status == 200

    status, body = vote(event_id, entry_id, voter, *PARIS)
    assert status == 200 and body["accepted"] is True


def test_location_time_wrap_window_rejects_a_vote_outside_it(
    make_user, make_song, create_event, suggest, vote, set_vote_license
):
    """Complément du test précédent : une fenêtre qui traverse minuit doit
    aussi bien refuser un vote hors créneau qu'en accepter un dedans --
    sinon la branche "wrap" pourrait dégénérer en "toujours accepter" sans
    qu'aucun test ne le remarque."""
    host = make_user()
    voter = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    suggest(event_id, host, make_song())
    _, body = suggest(event_id, host, make_song())
    entry_id = int(body["queue"][0]["id"])

    start, end = _window_crossing_midnight_excluding_now(VENUE_TZ)
    status, _ = set_vote_license(
        event_id,
        host,
        vote_license="location_time",
        venue_latitude=PARIS[0],
        venue_longitude=PARIS[1],
        venue_radius_meters=200,
        vote_window_start=start,
        vote_window_end=end,
        vote_window_timezone=VENUE_TZ,
    )
    assert status == 200

    status, _ = vote(event_id, entry_id, voter, *PARIS)
    assert status == 403


def test_set_after_creation_is_host_only(make_user, create_event, set_vote_license):
    """La licence de vote n'est pas figée à la création : SetEventVoteLicense
    permet de la changer plus tard, mais seulement pour l'hôte -- n'importe
    qui d'autre reçoit un 403, même sur un event dont la licence de départ
    était "everyone" (donc ouverte à tous pour VOTER, mais pas pour changer
    les réglages)."""
    host = make_user()
    other = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])

    # Un participant quelconque ne peut pas changer la licence.
    status, _ = set_vote_license(event_id, other, vote_license="invited_only")
    assert status == 403

    # L'hôte, si.
    status, body = set_vote_license(event_id, host, vote_license="invited_only")
    assert status == 200
    assert body["event"]["voteLicense"] == "invited_only"
