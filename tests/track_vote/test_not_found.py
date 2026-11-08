"""Un id qui n'existe pas (par opposition à un id existant mais interdit,
couvert par test_visibility.py) reste un 404 simple."""

import uuid


def test_get_music_event_with_unknown_id_is_not_found(api, make_user, auth_headers):
    """Même une lecture toute simple, sur un id qui n'a jamais existé, doit
    répondre 404 -- distinct du cas "l'event existe mais il est privé" (qui
    donne aussi 404, volontairement, voir test_visibility.py) mais qui doit
    au moins fonctionner sans planter sur un id qui ne correspond à rien."""
    viewer = make_user()
    status, _ = api.get(f"/v1/events/{uuid.uuid4()}", headers=auth_headers(viewer))
    assert status == 404
