"""Helpers propres à Music Track Vote (V.2.1), exposés en fixtures pour que
chaque fichier de ce dossier les utilise sans rien importer (voir
tests/conftest.py pour les fixtures partagées entre les quatre services :
api, make_user, make_song, make_friendship, public_id_of, auth_headers,
eventually).

Même principe que tests/user et tests/playlist_editor : chaque route
identifie ses objets par public_id et authentifie l'appelant par bearer
token (proto/music_room/v1/services/event_service.proto,
backend/internal/interceptor/policy.go). `create_event` retient le
public_id de chaque event ET de chaque entrée de file qu'elle voit passer
(indexés par leur id interne), pour que le reste de ce fichier -- et les
tests -- continuent de manipuler des ids entiers ; elle attend aussi que la
tuple `host` fraîchement écrite (asynchrone, via l'outbox) soit visible
avant de rendre la main, comme create_playlist pour les mêmes raisons."""

import time

import pytest


@pytest.fixture
def create_event(api, auth_headers, eventually):
    event_public_ids = {}
    entry_public_ids = {}

    def _absorb(body):
        event = body.get("event")
        if event:
            event_public_ids[int(event["id"])] = event["publicId"]
        for entry in body.get("queue") or []:
            entry_public_ids[int(entry["id"])] = entry["publicId"]

    def _create(host_id, **overrides):
        payload = {"name": overrides.pop("name", "Test Event")}
        # Required (CreateEvent): starting now, for three hours.
        now = int(time.time())
        payload.update(startsAt=str(now), endsAt=str(now + 3 * 3600))
        payload.update(overrides)
        status, body = api.post("/v1/events", json=payload, headers=auth_headers(host_id))
        if status == 200:
            _absorb(body)
            event_public_id = event_public_ids[int(body["event"]["id"])]
            eventually(
                lambda: api.get(
                    f"/v1/events/{event_public_id}", headers=auth_headers(host_id)
                ),
                lambda status, _: status == 200,
            )
        return status, body

    _create.event_public_ids = event_public_ids
    _create.entry_public_ids = entry_public_ids
    _create.absorb = _absorb
    return _create


@pytest.fixture
def event_public_id_of(create_event):
    def _pid(event_id: int) -> str:
        return create_event.event_public_ids[event_id]

    return _pid


@pytest.fixture
def suggest(api, auth_headers, create_event, event_public_id_of):
    def _suggest(event_id, user_id, song, lat=0.0, lon=0.0):
        status, body = api.post(
            f"/v1/events/{event_public_id_of(event_id)}/queue",
            json={
                "deezer_song_id": song["deezer_song_id"],
                "suggester_latitude": lat,
                "suggester_longitude": lon,
            },
            headers=auth_headers(user_id),
        )
        if status == 200:
            create_event.absorb(body)
        return status, body

    return _suggest


@pytest.fixture
def vote(api, auth_headers, create_event, event_public_id_of):
    def _vote(event_id, entry_id, user_id, lat=0.0, lon=0.0):
        status, body = api.post(
            f"/v1/events/{event_public_id_of(event_id)}/queue/{create_event.entry_public_ids[entry_id]}/vote",
            json={"voter_latitude": lat, "voter_longitude": lon},
            headers=auth_headers(user_id),
        )
        if status == 200:
            create_event.absorb(body)
        return status, body

    return _vote


@pytest.fixture
def get_music_events(api, auth_headers, public_id_of):
    def _get(user_id, viewer_id):
        return api.get(
            f"/v1/users/{public_id_of(user_id)}/events", headers=auth_headers(viewer_id)
        )

    return _get


@pytest.fixture
def get_event(api, auth_headers, event_public_id_of):
    def _get(event_id, viewer_id):
        return api.get(
            f"/v1/events/{event_public_id_of(event_id)}", headers=auth_headers(viewer_id)
        )

    return _get


@pytest.fixture
def get_queue(api, auth_headers, create_event, event_public_id_of):
    def _get(event_id, viewer_id):
        status, body = api.get(
            f"/v1/events/{event_public_id_of(event_id)}/queue", headers=auth_headers(viewer_id)
        )
        if status == 200:
            create_event.absorb({"queue": body.get("queue")})
        return status, body

    return _get


@pytest.fixture
def get_playback(api, auth_headers, event_public_id_of):
    def _get(event_id, viewer_id):
        return api.get(
            f"/v1/events/{event_public_id_of(event_id)}/playback", headers=auth_headers(viewer_id)
        )

    return _get


@pytest.fixture
def list_members(api, auth_headers, event_public_id_of):
    def _list(event_id, viewer_id):
        return api.get(
            f"/v1/events/{event_public_id_of(event_id)}/members", headers=auth_headers(viewer_id)
        )

    return _list


@pytest.fixture
def invite_to_event(api, public_id_of, auth_headers, event_public_id_of):
    def _invite(event_id, inviter_id, invitee_id):
        return api.post(
            f"/v1/events/{event_public_id_of(event_id)}/members",
            json={"invitee_user_public_id": public_id_of(invitee_id)},
            headers=auth_headers(inviter_id),
        )

    return _invite


@pytest.fixture
def set_visibility(api, auth_headers, event_public_id_of):
    def _set(event_id, actor_id, visibility):
        return api.patch(
            f"/v1/events/{event_public_id_of(event_id)}/visibility",
            json={"visibility": visibility},
            headers=auth_headers(actor_id),
        )

    return _set


@pytest.fixture
def set_vote_license(api, auth_headers, event_public_id_of):
    def _set(event_id, actor_id, **fields):
        return api.patch(
            f"/v1/events/{event_public_id_of(event_id)}/vote-license",
            json=fields,
            headers=auth_headers(actor_id),
        )

    return _set


@pytest.fixture
def play_next(api, auth_headers, event_public_id_of):
    def _next(event_id, user_id, **fields):
        return api.post(
            f"/v1/events/{event_public_id_of(event_id)}/playback/next",
            json=fields,
            headers=auth_headers(user_id),
        )

    return _next


@pytest.fixture
def set_playback(api, auth_headers, event_public_id_of):
    def _set(event_id, user_id, **fields):
        return api.patch(
            f"/v1/events/{event_public_id_of(event_id)}/playback",
            json=fields,
            headers=auth_headers(user_id),
        )

    return _set


@pytest.fixture
def remove_queue_entry(api, auth_headers, create_event, event_public_id_of):
    def _remove(event_id, entry_id, actor_id):
        return api.delete(
            f"/v1/events/{event_public_id_of(event_id)}/queue/{create_event.entry_public_ids[entry_id]}",
            headers=auth_headers(actor_id),
        )

    return _remove


@pytest.fixture
def set_event_status(db_conn):
    """Met l'événement dans [status] directement en base, comme le seed : seul
    le premier play le fait passer en `live` (PlayNextInEventQueue), et un
    test qui veut juste un événement en cours n'a pas besoin d'une file."""
    def _set(event_id, status):
        with db_conn.cursor() as cur:
            cur.execute("UPDATE events SET status = %s WHERE id = %s", (status, event_id))

    return _set


@pytest.fixture
def end_event(api, auth_headers, event_public_id_of):
    def _end(event_id, actor_id):
        return api.post(
            f"/v1/events/{event_public_id_of(event_id)}/end",
            headers=auth_headers(actor_id),
        )

    return _end


@pytest.fixture
def delete_event(api, auth_headers, event_public_id_of):
    def _delete(event_id, actor_id):
        return api.delete(
            f"/v1/events/{event_public_id_of(event_id)}", headers=auth_headers(actor_id)
        )

    return _delete
