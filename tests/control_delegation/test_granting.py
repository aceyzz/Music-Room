"""V.2.2 : seul le propriétaire de l'appareil peut déléguer son contrôle, et
seulement à un ami ("give the music control to different friends")."""


def test_requires_device_ownership(make_user, make_friendship, register_device, grant_control):
    """Le device_id appartient à `owner`, mais c'est `not_the_owner` qui
    tente d'en déléguer le contrôle (à un ami à LUI, pour être sûr que la
    friendship n'est pas la raison du refus) : la propriété de l'appareil
    doit primer, peu importe qui est ami avec qui."""
    owner = make_user()
    not_the_owner = make_user()
    friend = make_user()
    make_friendship(not_the_owner, friend)
    _, body = register_device(owner)
    device_id = int(body["device"]["id"])

    status, _ = grant_control(device_id, not_the_owner, friend)
    assert status == 403


def test_requires_friendship(make_user, register_device, grant_control):
    """Le sujet dit explicitement "different friends" -- la délégation est
    donc réservée aux amis (table `friendships`), pas ouverte à n'importe
    quel utilisateur de la plateforme : ici owner et stranger n'ont aucune
    relation d'amitié, la délégation doit être refusée même si owner
    possède bien l'appareil."""
    owner = make_user()
    stranger = make_user()
    _, body = register_device(owner)
    device_id = int(body["device"]["id"])

    status, _ = grant_control(device_id, owner, stranger)
    assert status == 403


def test_granting_the_same_scope_twice_conflicts(
    make_user, make_friendship, register_device, grant_control, create_event
):
    """L'index unique device_control_licenses_one_live_per_scope interdit
    deux délégations actives simultanées pour le même (appareil, ami,
    portée) : accorder deux fois la même délégation doit remonter comme un
    conflit (409), pas silencieusement créer une deuxième ligne redondante."""
    owner = make_user()
    friend = make_user()
    make_friendship(owner, friend)
    _, body = register_device(owner)
    device_id = int(body["device"]["id"])

    _, event_body = create_event(owner, name="Same scope")
    event_id = int(event_body["event"]["id"])

    status, _ = grant_control(device_id, owner, friend, event_id=event_id)
    assert status == 200

    # Même appareil, même ami, même événement : refusé.
    status, _ = grant_control(device_id, owner, friend, event_id=event_id)
    assert status == 409


def test_cannot_grant_control_to_yourself(make_user, register_device, grant_control):
    """Se déléguer le contrôle de son propre appareil à soi-même n'a pas de
    sens (on le contrôle déjà en tant que propriétaire) et est explicitement
    rejeté par la contrainte "grantee_user_id <> granted_by_id" -- ce test
    vérifie que l'API le refuse proprement (400) avant même d'atteindre la
    base plutôt que de laisser remonter une erreur SQL brute."""
    owner = make_user()
    _, body = register_device(owner)
    device_id = int(body["device"]["id"])

    status, _ = grant_control(device_id, owner, owner)
    assert status == 400
