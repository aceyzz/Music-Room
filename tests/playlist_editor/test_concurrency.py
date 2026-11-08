"""Exigence explicite du sujet : "You should especially care about the
management of competition problematics: for instance, if several people
move different tracks or the same one in a playlist." Comme pour
track_vote/test_concurrency.py, ces tests envoient de vrais appels HTTP en
parallèle plutôt que de simuler la concurrence : c'est le seul moyen de
vérifier que le verrouillage de ligne (BumpPlaylistRevision, cf.
db/query/playlists.sql) fait effectivement son travail."""

from concurrent.futures import ThreadPoolExecutor


def test_concurrent_additions_from_different_members_all_land(
    make_user, make_song, create_playlist, invite_to_playlist, add_song, get_playlist, eventually
):
    """8 membres différents ajoutent chacun un morceau à la MÊME playlist en
    même temps. BumpPlaylistRevision prend un verrou exclusif sur la ligne
    playlists avant chaque ajout, ce qui sérialise les écritures : les 8
    ajouts doivent tous réussir, revision doit finir exactement à 8 (pas de
    saut ni de collision sur le même numéro), et les 8 morceaux doivent tous
    être présents -- aucun perdu par une écriture concurrente."""
    owner = make_user()
    editors = [make_user() for _ in range(8)]
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])
    for editor in editors:
        status, _ = invite_to_playlist(playlist_id, owner, editor)
        assert status == 200
    songs = [make_song() for _ in editors]

    # Chaque invitation vient d'écrire une tuple via l'outbox (asynchrone) :
    # laisser le temps à la dernière de se propager avant de lancer les
    # écritures concurrentes (une lecture, pas un ajout, pour ne pas fausser
    # les compteurs vérifiés plus bas), sinon un editor pourrait se faire
    # refuser pour une raison de timing plutôt que par le verrouillage qu'on
    # veut tester. can_edit_songs découle de la même tuple que can_view ici
    # (edit_license par défaut = "everyone", donc can_view suffit).
    last_editor = editors[-1]
    eventually(lambda: get_playlist(playlist_id, last_editor), lambda status, _: status == 200)

    def add(pair):
        editor, song = pair
        return add_song(playlist_id, song, editor)

    # Un thread par éditeur, tous lancés en même temps.
    with ThreadPoolExecutor(max_workers=len(editors)) as pool:
        results = list(pool.map(add, zip(editors, songs)))

    assert all(status == 200 for status, _ in results)

    status, body = get_playlist(playlist_id, owner)
    assert status == 200
    assert body["playlist"]["songCount"] == len(editors)
    assert int(body["playlist"]["revision"]) == len(editors)
    assert len(body["songs"]) == len(editors)


def test_concurrent_moves_of_different_songs_all_land(
    make_user, make_song, create_playlist, add_song, move_song, get_playlist
):
    """Complète le test ci-dessus sur l'autre moitié de la citation du sujet
    ("move different tracks or the same one") : 8 utilisateurs déplacent
    chacun un morceau DIFFÉRENT en tête (`after_playlist_song_id=0`) en même
    temps. Design relatif, pas de `base_revision` : BumpPlaylistRevision
    sérialise l'accès à la ligne playlists, donc les 8 écritures s'appliquent
    l'une après l'autre sur l'ordre tel qu'il est à ce moment-là plutôt que
    d'être comparées à une revision lue avant le lancement -- les 8 doivent
    réussir, aucune rejetée, aucun morceau perdu."""
    owner = make_user()
    _, body = create_playlist(owner)
    playlist_id = int(body["playlist"]["id"])

    playlist_song_ids = []
    for _ in range(8):
        status, body = add_song(playlist_id, make_song(), owner)
        playlist_song_ids.append(int(body["songs"][-1]["id"]))
    base_revision = int(body["playlist"]["revision"])
    assert base_revision == 8

    def move(playlist_song_id):
        return move_song(playlist_id, playlist_song_id, after_playlist_song_id=0, user_id=owner)

    with ThreadPoolExecutor(max_workers=len(playlist_song_ids)) as pool:
        results = list(pool.map(move, playlist_song_ids))

    statuses = [status for status, _ in results]
    assert statuses.count(200) == len(playlist_song_ids), statuses

    # Chaque move a bumpé la revision une fois, rien perdu ni dupliqué.
    status, body = get_playlist(playlist_id, owner)
    assert status == 200
    assert int(body["playlist"]["revision"]) == base_revision + len(playlist_song_ids)
    assert len(body["songs"]) == len(playlist_song_ids)
    assert {int(s["id"]) for s in body["songs"]} == set(playlist_song_ids)
