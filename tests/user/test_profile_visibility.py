"""V.1 : le profil a 3 niveaux de visibilité par champ (public / friends /
private, docs/data-model.md §6). Le propriétaire voit toujours tout ; sinon
public passe à tout le monde, friends seulement à un ami, private à
personne d'autre que le propriétaire."""


def test_new_user_has_schema_defaults_and_empty_fields(get_user, make_user):
    """Avant tout appel à UpdateUserProfile, user_profiles n'a pas de ligne
    -- GetUser doit quand même répondre avec les valeurs par défaut du
    schéma (db/schema/00008_profile.sql) plutôt qu'échouer ou renvoyer des
    visibilités vides."""
    user = make_user()

    status, body = get_user(user, viewer_id=user)
    assert status == 200
    profile = body["user"]
    assert profile["firstNameVisibility"] == "friends"
    assert profile["lastNameVisibility"] == "friends"
    assert profile["bioVisibility"] == "public"
    assert profile["birthDateVisibility"] == "private"
    assert profile["locationVisibility"] == "friends"
    assert profile["phoneVisibility"] == "private"
    assert profile["preferencesVisibility"] == "public"
    assert profile["firstName"] == ""
    assert profile["musicPreferences"] == []


def test_owner_sees_everything_regardless_of_visibility(get_user, update_profile, make_user):
    """Même un champ private (birth_date par défaut) reste visible pour son
    propre propriétaire : la visibilité restreint les AUTRES, jamais soi."""
    user = make_user()
    update_profile(
        user, first_name="Alice", birth_date="1995-05-20", phone_number="0600000000"
    )

    status, body = get_user(user, viewer_id=user)
    assert status == 200
    profile = body["user"]
    assert profile["firstName"] == "Alice"
    assert profile["birthDate"] == "1995-05-20"
    assert profile["phoneNumber"] == "0600000000"


def test_stranger_sees_only_public_fields(get_user, update_profile, make_user):
    """bio est public par défaut ; first_name/last_name (friends) et
    birth_date/phone (private) doivent rester cachés à un utilisateur qui
    n'est ni le propriétaire ni un ami."""
    owner = make_user()
    stranger = make_user()
    update_profile(
        owner,
        first_name="Alice",
        bio="j'adore la musique",
        birth_date="1995-05-20",
        phone_number="0600000000",
    )

    status, body = get_user(owner, viewer_id=stranger)
    assert status == 200
    profile = body["user"]
    assert profile["bio"] == "j'adore la musique"
    assert profile["firstName"] == ""
    assert profile["birthDate"] == ""
    assert profile["phoneNumber"] == ""


def test_unauthenticated_request_is_rejected(api, make_user, public_id_of, update_profile):
    """GetUser n'a plus de notion de viewer "anonyme" (viewer_id=0) : chaque
    appel authentifie l'appelant, donc il n'y a plus de scope à part pour
    "personne de connecté" -- il ne reste que "pas de token du tout", qui
    doit être refusé avant même d'atteindre une question de visibilité. Voir
    test_stranger_sees_only_public_fields pour le cas "un vrai compte qui
    n'est ni le propriétaire ni un ami", qui est ce que l'ancien scénario
    "anonyme" testait en pratique."""
    owner = make_user()
    update_profile(owner, first_name="Alice", bio="public bio")

    status, _ = api.get(f"/v1/users/{public_id_of(owner)}")
    assert status == 401


def test_friend_sees_friends_scope_but_not_private(get_user, update_profile, make_user, make_friendship):
    """Une fois amis, first_name/last_name (friends) et city/country_code
    (location, aussi friends) doivent devenir visibles, mais birth_date et
    phone_number (private) restent cachés même à un ami."""
    owner = make_user()
    friend = make_user()
    make_friendship(owner, friend)
    update_profile(
        owner,
        first_name="Alice",
        last_name="Dupont",
        city="Paris",
        country_code="FR",
        birth_date="1995-05-20",
        phone_number="0600000000",
    )

    status, body = get_user(owner, viewer_id=friend)
    assert status == 200
    profile = body["user"]
    assert profile["firstName"] == "Alice"
    assert profile["lastName"] == "Dupont"
    assert profile["city"] == "Paris"
    assert profile["countryCode"] == "FR"
    assert profile["birthDate"] == ""
    assert profile["phoneNumber"] == ""


def test_partial_update_leaves_other_fields_unchanged(get_user, update_profile, make_user):
    """Une chaîne vide sur un champ non envoyé veut dire "inchangé", pas
    "vider" (même compromis que db/query/profiles.sql:UpsertUserProfile) :
    mettre à jour bio seule ne doit pas effacer first_name posé avant."""
    user = make_user()
    update_profile(user, first_name="Alice")

    status, body = update_profile(user, bio="nouvelle bio")
    assert status == 200
    assert body["user"]["firstName"] == "Alice"
    assert body["user"]["bio"] == "nouvelle bio"


def test_widening_visibility_takes_effect_immediately(get_user, update_profile, make_user):
    """Changer birth_date_visibility à public doit réellement débloquer la
    lecture pour un stranger dès l'appel suivant, pas seulement renvoyer
    200 sans effet."""
    owner = make_user()
    stranger = make_user()
    update_profile(owner, birth_date="1995-05-20")
    assert get_user(owner, viewer_id=stranger)[1]["user"]["birthDate"] == ""

    status, body = update_profile(owner, birth_date_visibility="public")
    assert status == 200
    assert body["user"]["birthDate"] == "1995-05-20"

    status, body = get_user(owner, viewer_id=stranger)
    assert status == 200
    assert body["user"]["birthDate"] == "1995-05-20"


def test_invalid_visibility_value_is_rejected(update_profile, make_user):
    user = make_user()
    status, _ = update_profile(user, bio_visibility="everyone")
    assert status == 400


def test_invalid_birth_date_format_is_rejected(update_profile, make_user):
    user = make_user()
    status, _ = update_profile(user, birth_date="20/05/1995")
    assert status == 400
