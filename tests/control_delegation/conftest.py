"""Helpers propres à Music Control Delegation (V.2.2), exposés en fixtures
pour que chaque fichier de ce dossier les utilise sans rien importer (voir
tests/conftest.py pour les fixtures partagées entre les quatre services :
api, make_user, make_song, make_friendship, public_id_of, auth_headers,
eventually).

Même principe que les trois autres dossiers : chaque route identifie ses
objets par public_id et authentifie l'appelant par bearer token (proto/
music_room/v1/services/delegation_service.proto,
backend/internal/interceptor/policy.go). `register_device` attend que la
tuple `owner` fraîchement écrite (asynchrone, via l'outbox) soit visible
avant de rendre la main -- comme create_playlist/create_event -- puisque
GrantDeviceControl vérifie can_grant_control (owner) sur le device juste
après.

Ce dossier a aussi besoin d'events (EventService) pour les tests
d'intégration avec la lecture (test_standing_grant.py,
test_playback_delegation.py) : pas de fixture partagée entre répertoires de
tests, donc une version minimale de create_event/suggest vit ici plutôt que
d'importer tests/track_vote/conftest.py."""

import time

import pytest


@pytest.fixture
def register_device(api, public_id_of, auth_headers, eventually):
    device_public_ids = {}

    def _register(user_id, identifier=None, platform="ios"):
        status, body = api.post(
            f"/v1/users/{public_id_of(user_id)}/devices",
            json={
                "device_identifier": identifier or f"device-{user_id}",
                "name": "Test Device",
                "platform": platform,
            },
            headers=auth_headers(user_id),
        )
        if status == 200:
            device_id = int(body["device"]["id"])
            device_public_id = body["device"]["publicId"]
            device_public_ids[device_id] = device_public_id
            eventually(
                lambda: api.get(
                    f"/v1/devices/{device_public_id}/control-licenses",
                    headers=auth_headers(user_id),
                ),
                lambda status, _: status == 200,
            )
        return status, body

    _register.public_ids = device_public_ids
    return _register


@pytest.fixture
def device_public_id_of(register_device):
    def _pid(device_id: int) -> str:
        return register_device.public_ids[device_id]

    return _pid


@pytest.fixture
def list_my_devices(api, public_id_of, auth_headers):
    def _list(user_id):
        return api.get(f"/v1/users/{public_id_of(user_id)}/devices", headers=auth_headers(user_id))

    return _list


@pytest.fixture
def grant_control(api, public_id_of, auth_headers, device_public_id_of, event_public_id_of, create_event):
    """Une licence vaut pour UN événement (00021) : sans event_id, un
    événement neuf de celui qui accorde est créé pour l'occasion. standing=True
    envoie le don sans événement, pour vérifier que le serveur le refuse."""
    def _grant(device_id, granter_id, grantee_id, event_id=None, standing=False):
        payload = {"grantee_user_public_id": public_id_of(grantee_id)}
        if not standing:
            if event_id is None:
                _, body = create_event(granter_id, name="Licence scope")
                event_id = int(body["event"]["id"])
            payload["event_public_id"] = event_public_id_of(event_id)
        return api.post(
            f"/v1/devices/{device_public_id_of(device_id)}/control-licenses",
            json=payload,
            headers=auth_headers(granter_id),
        )

    return _grant


@pytest.fixture
def revoke_control(api, auth_headers, device_public_id_of):
    def _revoke(device_id, license_id, revoker_id):
        return api.delete(
            f"/v1/devices/{device_public_id_of(device_id)}/control-licenses/{license_id}",
            headers=auth_headers(revoker_id),
        )

    return _revoke


@pytest.fixture
def list_licenses(api, auth_headers, device_public_id_of):
    def _list(device_id, viewer_id):
        return api.get(
            f"/v1/devices/{device_public_id_of(device_id)}/control-licenses",
            headers=auth_headers(viewer_id),
        )

    return _list


# --- Le strict nécessaire d'EventService pour les scénarios d'intégration --

@pytest.fixture
def create_event(api, auth_headers, eventually):
    event_public_ids = {}

    def _create(host_id, **overrides):
        payload = {"name": overrides.pop("name", "Test Event")}
        # Required (CreateEvent): starting now, for three hours.
        now = int(time.time())
        payload.update(startsAt=str(now), endsAt=str(now + 3 * 3600))
        payload.update(overrides)
        status, body = api.post("/v1/events", json=payload, headers=auth_headers(host_id))
        if status == 200:
            event_id = int(body["event"]["id"])
            event_public_id = body["event"]["publicId"]
            event_public_ids[event_id] = event_public_id
            eventually(
                lambda: api.get(
                    f"/v1/events/{event_public_id}", headers=auth_headers(host_id)
                ),
                lambda status, _: status == 200,
            )
        return status, body

    _create.public_ids = event_public_ids
    return _create


@pytest.fixture
def event_public_id_of(create_event):
    def _pid(event_id: int) -> str:
        return create_event.public_ids[event_id]

    return _pid


@pytest.fixture
def suggest(api, auth_headers, event_public_id_of):
    def _suggest(event_id, user_id, song):
        return api.post(
            f"/v1/events/{event_public_id_of(event_id)}/queue",
            json={"deezer_song_id": song["deezer_song_id"]},
            headers=auth_headers(user_id),
        )

    return _suggest


@pytest.fixture
def play_next(api, auth_headers, event_public_id_of):
    """L'hôte appuie sur lecture : la radio ne démarre jamais toute seule,
    ni à la création ni sur une suggestion (docs/todo.md §4, D3)."""
    def _next(event_id, user_id):
        return api.post(
            f"/v1/events/{event_public_id_of(event_id)}/playback/next",
            json={},
            headers=auth_headers(user_id),
        )

    return _next


@pytest.fixture
def set_event_playback(api, auth_headers, event_public_id_of):
    """Pas d'appareil dans la requête : la licence d'un délégué est vérifiée
    contre l'enceinte de l'événement (SetEventSpeaker)."""
    def _set(event_id, user_id, **fields):
        return api.patch(
            f"/v1/events/{event_public_id_of(event_id)}/playback",
            json=fields,
            headers=auth_headers(user_id),
        )

    return _set
