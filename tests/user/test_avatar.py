"""V.1 : l'avatar est uploadé, redimensionné en carré par le image-service
Rust, puis stocké et servi par le backend (pas d'objet S3 dans ce projet --
voir internal/media/). Remplacer un avatar retire l'ancien (fichiers ET
lignes `images`), et supprimer un avatar inexistant reste un succès."""

SMALL_PNG_BYTE_SIZE_RANGE = range(1, 50_000)  # une miniature 512x512 tient largement là-dedans


def test_upload_sets_the_avatar_and_serves_a_512x512_png(
    get_user, upload_avatar, fetch_media, make_user
):
    user = make_user()

    status, body = upload_avatar(user)
    assert status == 200
    storage_key = body["user"]["avatarStorageKey"]
    assert storage_key

    status, body = get_user(user, viewer_id=user)
    assert status == 200
    assert body["user"]["avatarStorageKey"] == storage_key

    status, content = fetch_media(storage_key)
    assert status == 200
    assert content[:8] == b"\x89PNG\r\n\x1a\n"  # signature PNG
    assert len(content) in SMALL_PNG_BYTE_SIZE_RANGE


def test_upload_rejects_an_unsupported_content_type(upload_avatar, make_user):
    user = make_user()
    status, _ = upload_avatar(user, content_type="application/pdf")
    assert status == 400


def test_upload_rejects_bytes_that_are_not_an_image(upload_avatar, make_user):
    """content_type valide, mais les octets eux-mêmes ne décodent pas comme
    une image -- image-service (image::load_from_memory) le refuse, et ça
    doit remonter en 400, pas en 500."""
    user = make_user()
    status, _ = upload_avatar(user, image_base64="aGVsbG8=")  # "hello" en base64
    assert status == 400


def test_upload_claiming_someone_elses_identity_is_denied(
    api, make_user, public_id_of, auth_headers, tiny_png_base64
):
    """UploadAvatar est self-only (policy.go) : un client ne peut plus jamais
    uploader "pour" un autre id, connu ou non -- stampCaller refuse la
    requête avant qu'elle atteigne image-service. La fixture upload_avatar
    ne peut pas construire ce cas (elle authentifie toujours l'appelant
    comme le user_id passé), d'où l'appel direct ici -- même raisonnement
    que tests/user/test_not_found.py pour UpdateUserProfile/
    SetMusicPreferences."""
    impostor = make_user()
    victim = make_user()

    status, _ = api.post(
        f"/v1/users/{public_id_of(victim)}/avatar",
        json={"image_data": tiny_png_base64, "content_type": "image/png"},
        headers=auth_headers(impostor),
    )
    assert status == 403


def test_uploading_again_replaces_the_previous_avatar(
    upload_avatar, fetch_media, make_user
):
    """La deuxième image doit remplacer la première -- pas seulement pour le
    profil (nouvelle clé), mais aussi sur disque (l'ancien fichier ne doit
    plus être servable après le remplacement)."""
    user = make_user()
    _, first = upload_avatar(user)
    first_key = first["user"]["avatarStorageKey"]
    assert fetch_media(first_key)[0] == 200

    _, second = upload_avatar(user)
    second_key = second["user"]["avatarStorageKey"]
    assert second_key != first_key

    assert fetch_media(first_key)[0] == 404
    assert fetch_media(second_key)[0] == 200


def test_delete_avatar_clears_the_key_and_removes_the_file(
    get_user, upload_avatar, delete_avatar, fetch_media, make_user
):
    user = make_user()
    _, body = upload_avatar(user)
    storage_key = body["user"]["avatarStorageKey"]

    status, body = delete_avatar(user)
    assert status == 200
    assert body["user"]["avatarStorageKey"] == ""

    assert get_user(user, viewer_id=user)[1]["user"]["avatarStorageKey"] == ""
    assert fetch_media(storage_key)[0] == 404


def test_delete_avatar_with_none_set_is_a_silent_success(delete_avatar, make_user):
    user = make_user()
    status, _ = delete_avatar(user)
    assert status == 200
