"""docs/todo.md §6 : chaque appel gRPC/REST écrit une ligne dans
activity_logs (schéma et requête CreateActivityLog déjà en place depuis le
début -- db/schema/00014_activity_logs.sql, db/query/activity_logs.sql --
jamais appelée avant ce point). L'écriture est asynchrone (goroutine,
best-effort dans internal/interceptor/activitylog.go) pour ne jamais
ralentir la requête qu'elle décrit, d'où le passage par `eventually` plutôt
qu'une lecture immédiate."""

import time
import uuid


def _latest_log(db_conn, action, user_id=None):
    with db_conn.cursor() as cur:
        if user_id is None:
            cur.execute(
                "SELECT user_id, result_code, metadata, created_at, resource_type, resource_id "
                "FROM activity_logs WHERE action = %s AND user_id IS NULL "
                "ORDER BY created_at DESC LIMIT 1",
                (action,),
            )
        else:
            cur.execute(
                "SELECT user_id, result_code, metadata, created_at, resource_type, resource_id "
                "FROM activity_logs WHERE action = %s AND user_id = %s "
                "ORDER BY created_at DESC LIMIT 1",
                (action, user_id),
            )
        return cur.fetchone()


def test_successful_call_is_logged_with_headers(make_user, api, auth_headers, db_conn, eventually):
    host = make_user()
    action = "/music_room.v1.PlaylistService/CreatePlaylist"
    headers = {
        **auth_headers(host),
        "x-platform": "ios",
        "x-device-model": "iPhone15,3",
        "x-app-version": "1.2.3",
    }

    status, _ = api.post("/v1/playlists", json={"name": "Activity log test"}, headers=headers)
    assert status == 200

    row = eventually(
        lambda: (_latest_log(db_conn, action, host),),
        lambda row: row is not None,
    )[0]
    assert row is not None
    user_id, result_code, metadata, _, resource_type, resource_id = row
    assert user_id == host
    assert result_code == 0  # codes.OK
    # psycopg2 désérialise déjà JSONB en dict -- pas de json.loads ici.
    assert metadata == {
        "x-platform": "ios",
        "x-device-model": "iPhone15,3",
        "x-app-version": "1.2.3",
    }
    # CreatePlaylist n'a pas de Requirement (rien à résoudre : l'objet
    # n'existe pas encore) -- pas de resource_type/resource_id ici,
    # contrairement au test suivant.
    assert resource_type is None
    assert resource_id is None


def test_successful_call_with_a_resolved_object_logs_its_resource(
    make_user, api, auth_headers, db_conn, eventually
):
    """resource_type/resource_id ne sont pas le body de la requête (voir
    docs/authz-enforcement.md §Activity logging pour pourquoi -- un log de
    sécurité gardé deux ans n'est pas l'endroit où mettre un mot de passe) :
    c'est l'objet que l'intercepteur a déjà résolu pour la Requirement,
    relu après coup (StampField) plutôt qu'un deuxième canal."""
    host = make_user()
    status, body = api.post(
        "/v1/playlists", json={"name": "Resource log test"}, headers=auth_headers(host)
    )
    assert status == 200
    playlist_id = int(body["playlist"]["id"])
    playlist_public_id = body["playlist"]["publicId"]
    action = "/music_room.v1.PlaylistService/GetPlaylist"

    status, _ = api.get(f"/v1/playlists/{playlist_public_id}", headers=auth_headers(host))
    assert status == 200

    row = eventually(
        lambda: (_latest_log(db_conn, action, host),),
        lambda row: row is not None,
    )[0]
    assert row is not None
    _, result_code, _, _, resource_type, resource_id = row
    assert result_code == 0
    assert resource_type == "playlist"
    assert resource_id == playlist_id


def test_permission_denial_is_logged_with_result_code_7_and_the_caller(
    make_user, api, auth_headers, db_conn, eventually
):
    """result_code = 7 est codes.PermissionDenied -- exactement ce que
    docs/todo.md §6 demande de garantir. L'appelant est bien identifié même
    si la requête est refusée : il a passé l'authentification, seule
    l'autorisation sur l'objet (une playlist inexistante ici) échoue."""
    host = make_user()
    action = "/music_room.v1.PlaylistService/DeletePlaylist"

    status, _ = api.delete(f"/v1/playlists/{uuid.uuid4()}", headers=auth_headers(host))
    assert status == 403

    row = eventually(
        lambda: (_latest_log(db_conn, action, host),),
        lambda row: row is not None,
    )[0]
    assert row is not None
    user_id, result_code, _, _, resource_type, resource_id = row
    assert user_id == host
    assert result_code == 7
    # Refusé avant même la résolution (Check échoue avant Resolve, voir
    # enforce() dans internal/interceptor/interceptor.go) : pas d'id à
    # divulguer pour un objet que l'appelant n'a jamais eu le droit de voir.
    assert resource_type is None
    assert resource_id is None


def test_unauthenticated_call_is_logged_without_a_user(api, db_conn, eventually):
    action = "/music_room.v1.PlaylistService/CreatePlaylist"
    # Marqueur temporel pour ne pas confondre avec une ligne anonyme plus
    # ancienne laissée par un test précédent -- il n'y a pas d'user_id ici
    # pour cibler la bonne ligne autrement.
    before = time.time()

    status, _ = api.post(
        "/v1/playlists", json={"name": "x"}, headers={"Authorization": "Bearer not-a-real-token"}
    )
    assert status == 401

    row = eventually(
        lambda: (_latest_log(db_conn, action, user_id=None),),
        lambda row: row is not None and row[3].timestamp() >= before,
    )[0]
    assert row is not None
    user_id, result_code, _, _, _, _ = row
    assert user_id is None
    assert result_code == 16  # codes.Unauthenticated
