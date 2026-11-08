"""Event lifecycle (docs/permissions.md §13) : scheduled -> live -> ended,
`ended` terminal. Le premier play du host fait passer l'événement en `live`
(test_status_residuals.py::test_first_play_promotes_scheduled_to_live) ;
EndEvent est la seule transition demandée par une requête. can_change_status
(host ou admin) est vérifié par l'intercepteur ; ce fichier vérifie les états
depuis lesquels EndEvent est légal (la comparaison de statut dans la requête
SQL)."""

def test_a_scheduled_event_can_be_ended(make_user, create_event, end_event):
    """The app has End event, not Delete: it also closes an event that
    never started."""
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])

    status, body = end_event(event_id, host)
    assert status == 200
    assert body["event"]["status"] == "ended"


def test_end_is_legal_from_live(make_user, create_event, set_event_status, end_event):
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    set_event_status(event_id, "live")

    status, body = end_event(event_id, host)
    assert status == 200
    assert body["event"]["status"] == "ended"


def test_ended_is_terminal(make_user, create_event, end_event):
    host = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    end_event(event_id, host)

    status, _ = end_event(event_id, host)
    assert status == 400  # FailedPrecondition


def test_non_host_cannot_end(make_user, create_event, invite_to_event, end_event, eventually):
    host = make_user()
    member = make_user()
    _, body = create_event(host)
    event_id = int(body["event"]["id"])
    invite_to_event(event_id, host, member)

    # can_change_status est host ou admin -- un simple membre invité (rôle
    # par défaut : editor) n'y a pas droit.
    status, _ = eventually(
        lambda: end_event(event_id, member),
        lambda status, _: status != 404,  # laisse le temps à l'invitation.
    )
    assert status == 403
