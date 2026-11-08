"""RevokeDeviceControl : seul le propriétaire de l'appareil peut retirer une
délégation qu'il a accordée.

Ce test vérifie la liste des délégations (avant/après) ; pour vérifier que
révoquer coupe vraiment l'ACCÈS (et pas juste la ligne dans la liste), voir
control_delegation/test_standing_grant.py::test_revoking_removes_playback_control.
"""


def test_grant_then_revoke_round_trip(
    make_user, make_friendship, register_device, grant_control, list_licenses, revoke_control
):
    """Cycle de vie complet d'une délégation : on l'accorde (elle apparaît
    dans ListDeviceControlLicenses), on vérifie que seul le propriétaire de
    l'appareil peut la révoquer (l'ami lui-même ne le peut pas, même si
    c'est SA délégation qui est en jeu), puis on la révoque et on confirme
    qu'elle a bien disparu de la liste."""
    owner = make_user()
    friend = make_user()
    make_friendship(owner, friend)
    _, body = register_device(owner)
    device_id = int(body["device"]["id"])

    status, body = grant_control(device_id, owner, friend)
    assert status == 200
    license_id = int(body["license"]["id"])
    assert int(body["license"]["granteeUserId"]) == friend

    status, body = list_licenses(device_id, owner)
    assert status == 200
    assert [int(item["id"]) for item in body["licenses"]] == [license_id]

    # Seul le propriétaire peut révoquer. can_revoke_control (owner) est
    # désormais vérifié par l'intercepteur AVANT le handler -- friend n'a
    # pas la tuple `owner` sur ce device, donc c'est un refus de permission
    # (403), plus le "404 scopé par la requête SQL" d'avant l'intercepteur
    # (qui ne voyait jamais cette requête).
    status, _ = revoke_control(device_id, license_id, friend)
    assert status == 403

    # Le vrai propriétaire, en revanche, révoque sans problème.
    status, _ = revoke_control(device_id, license_id, owner)
    assert status == 200

    status, body = list_licenses(device_id, owner)
    assert status == 200
    assert body["licenses"] == []
