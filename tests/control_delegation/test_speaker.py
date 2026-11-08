"""SetEventSpeaker : l'hôte choisit lequel de ses appareils joue la musique
d'un événement (son enceinte), et les licences de l'événement suivent
l'enceinte. Avant, l'enceinte était l'appareil du premier play de l'hôte, et
ne changeait plus."""


def _speaker(api, auth_headers, event_public_id_of, event_id, user_id):
    status, body = api.get(
        f"/v1/events/{event_public_id_of(event_id)}/playback", headers=auth_headers(user_id)
    )
    assert status == 200
    return body["playback"].get("speakerDeviceId", "0")


def _set_speaker(api, auth_headers, event_public_id_of, device_public_id_of, event_id, user_id, device_id):
    return api.put(
        f"/v1/events/{event_public_id_of(event_id)}/speaker",
        json={"device_public_id": device_public_id_of(device_id)},
        headers=auth_headers(user_id),
    )


def _live_event(make_user, make_song, register_device, create_event, suggest, play_next, identifier):
    """Un événement dont l'hôte a appuyé sur lecture depuis l'appareil
    [identifier] : c'est son enceinte."""
    host = make_user()
    _, body = register_device(host, identifier=identifier)
    first = int(body["device"]["id"])
    _, event_body = create_event(host, name="Speaker")
    event_id = int(event_body["event"]["id"])
    suggest(event_id, host, make_song())
    play_next(event_id, host)
    return host, first, event_id


def test_the_host_picks_the_device_that_plays(
    api, auth_headers, make_user, make_song, register_device, device_public_id_of,
    create_event, event_public_id_of, suggest, play_next,
):
    host, phone, event_id = _live_event(
        make_user, make_song, register_device, create_event, suggest, play_next, "phone")
    assert _speaker(api, auth_headers, event_public_id_of, event_id, host) == str(phone)

    _, body = register_device(host, identifier="laptop")
    laptop = int(body["device"]["id"])
    status, body = _set_speaker(
        api, auth_headers, event_public_id_of, device_public_id_of, event_id, host, laptop)
    assert status == 200
    assert body["device"]["publicId"] == device_public_id_of(laptop)
    assert _speaker(api, auth_headers, event_public_id_of, event_id, host) == str(laptop)


def test_a_friend_in_control_follows_the_speaker_to_the_new_device(
    api, auth_headers, public_id_of, make_user, make_friendship, make_song, register_device,
    device_public_id_of, create_event, event_public_id_of, suggest, play_next,
    grant_control, list_licenses, set_event_playback, eventually,
):
    host, phone, event_id = _live_event(
        make_user, make_song, register_device, create_event, suggest, play_next, "phone")
    friend = make_user()
    make_friendship(host, friend)
    status, _ = grant_control(phone, host, friend, event_id=event_id)
    assert status == 200

    _, body = register_device(host, identifier="laptop")
    laptop = int(body["device"]["id"])
    status, _ = _set_speaker(
        api, auth_headers, event_public_id_of, device_public_id_of, event_id, host, laptop)
    assert status == 200

    # The licence moved: gone from the phone, on the laptop, for the same friend.
    _, body = list_licenses(phone, host)
    assert body.get("licenses", []) == []
    _, body = list_licenses(laptop, host)
    assert [l["granteeUserPublicId"] for l in body["licenses"]] == [public_id_of(friend)]
    assert body["licenses"][0]["eventPublicId"] == event_public_id_of(event_id)

    # And the friend still controls the music (the tuples go through the
    # outbox: eventually).
    status, _ = eventually(
        lambda: set_event_playback(event_id, friend, is_paused=True),
        lambda status, _: status == 200,
    )
    assert status == 200


def test_moving_the_speaker_back_and_forth_keeps_one_licence(
    api, auth_headers, make_user, make_friendship, make_song, register_device,
    device_public_id_of, create_event, event_public_id_of, suggest, play_next,
    grant_control, list_licenses,
):
    host, phone, event_id = _live_event(
        make_user, make_song, register_device, create_event, suggest, play_next, "phone")
    friend = make_user()
    make_friendship(host, friend)
    grant_control(phone, host, friend, event_id=event_id)
    _, body = register_device(host, identifier="laptop")
    laptop = int(body["device"]["id"])

    for device in (laptop, phone, laptop):
        status, _ = _set_speaker(
            api, auth_headers, event_public_id_of, device_public_id_of, event_id, host, device)
        assert status == 200

    _, body = list_licenses(phone, host)
    assert body.get("licenses", []) == []
    _, body = list_licenses(laptop, host)
    assert len(body["licenses"]) == 1


def test_only_the_host_picks_it(
    api, auth_headers, make_user, make_friendship, make_song, register_device,
    device_public_id_of, create_event, event_public_id_of, suggest, play_next,
):
    host, phone, event_id = _live_event(
        make_user, make_song, register_device, create_event, suggest, play_next, "phone")
    friend = make_user()
    make_friendship(host, friend)
    _, body = register_device(friend, identifier="friend-phone")
    friends_phone = int(body["device"]["id"])

    # A friend, on their own device: not their event.
    status, _ = _set_speaker(
        api, auth_headers, event_public_id_of, device_public_id_of, event_id, friend, friends_phone)
    assert status in (403, 404)
    # The host, on the friend's device: not their device.
    status, _ = _set_speaker(
        api, auth_headers, event_public_id_of, device_public_id_of, event_id, host, friends_phone)
    assert status in (403, 404)
    assert _speaker(api, auth_headers, event_public_id_of, event_id, host) == str(phone)


def test_not_on_an_ended_event(
    api, auth_headers, make_user, make_song, register_device, device_public_id_of,
    create_event, event_public_id_of, suggest, play_next,
):
    host, phone, event_id = _live_event(
        make_user, make_song, register_device, create_event, suggest, play_next, "phone")
    status, _ = api.post(
        f"/v1/events/{event_public_id_of(event_id)}/end", json={}, headers=auth_headers(host))
    assert status == 200

    _, body = register_device(host, identifier="laptop")
    laptop = int(body["device"]["id"])
    status, _ = _set_speaker(
        api, auth_headers, event_public_id_of, device_public_id_of, event_id, host, laptop)
    assert status == 400
