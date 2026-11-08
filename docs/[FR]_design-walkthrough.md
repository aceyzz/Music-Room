# Music Room : visite guidée de la conception

Un court tour de la façon dont Music Room est construit. Lisez ceci d'abord, puis ouvrez les diagrammes.

**Diagrammes.** Chaque fichier `walkthrough-*.html` du dossier `docs/diagrams/` est un diagramme interactif. Ouvrez-le dans un navigateur. Cliquez sur une boîte pour voir ce qu'elle fait, le fichier où elle se trouve et un
court extrait de vrai code. (Les diagrammes sont en anglais.)

| Diagramme | Ce qu'il montre |
| --- | --- |
| [Vue d'ensemble](diagrams/walkthrough-overview.html) | Tout le système sur une page |
| [Backend](diagrams/walkthrough-backend.html) | Le processus Go et ses services |
| [Pipeline de requête](diagrams/walkthrough-request-pipeline.html) | Ce qui arrive à une RPC avant que son handler s'exécute |
| [OpenFGA](diagrams/walkthrough-openfga.html) | Le service de permissions : modèle, checks, synchronisation |
| [Auth et sessions](diagrams/walkthrough-auth.html) | Comptes, connexions, tokens de session |
| [Temps réel](diagrams/walkthrough-realtime.html) | Comment un changement atteint chaque écran ouvert |
| [Frontend](diagrams/walkthrough-frontend.html) | L'app Flutter : démarrage, chemin des données, écrans en direct |
| [Track Vote](diagrams/walkthrough-track-vote.html) | Événements en direct avec une file votée |
| [Playlist Editor](diagrams/walkthrough-playlist-editor.html) | Playlists collaboratives |
| [Control Delegation](diagrams/walkthrough-control-delegation.html) | Laisser un ami piloter l'enceinte |
| [Modèle de données](diagrams/walkthrough-data-model.html) | Les principales tables Postgres (diagramme ER) |

---

## 1. Ce qu'est Music Room

Music Room est une application musicale collaborative (projet 42, sujet dans `en.subject.pdf`). Elle a trois fonctionnalités principales :

- **Track Vote** : un événement en direct où les invités proposent des morceaux et votent. Le morceau le plus voté passe ensuite.
- **Playlist Editor** : plusieurs personnes modifient la même playlist en même temps.
- **Control Delegation** : l'hôte laisse un ami contrôler l'enceinte de l'événement.

Autour : comptes et connexion (mot de passe, Google, 42), amis et blocages, profils et
avatars, et une recherche de morceaux Deezer.

---

## 2. Le système en un coup d'œil

[Diagramme : vue d'ensemble](diagrams/walkthrough-overview.html)

| Partie | Techno | Port (compose) | Rôle |
| --- | --- | --- | --- |
| App | Flutter / Dart | — | Le client : un APK Android, ou le build Linux dans un navigateur sur les machines d'éval |
| Backend | Go, gRPC + grpc-gateway | gRPC `50051`, REST `8081` | Toute la logique métier, un seul processus |
| Postgres | PostgreSQL | `5432` | **La source de vérité** |
| OpenFGA | openfga v1.18.3 + son propre Postgres | HTTP `8082` (`5433` pour sa base) | Le graphe de permissions |
| image-service | Rust, axum | `8080` | Redimensionne les images, ne stocke rien |
| Deezer | API HTTP publique | — | Le catalogue de chansons |

Le flux de base :
1. L'app appelle le backend en **gRPC natif**.
2. Un intercepteur vérifie la session et demande la permission à OpenFGA.
3. Un service du domaine lit et écrit dans Postgres.
4. Après l'écriture, le service envoie un signal pour que chaque flux « Watch » ouvert envoie un état à jour à son téléphone.

---

## 3. Le contrat : `proto/`

`proto/music_room/v1/` est l'**unique source de vérité** de l'API. Les messages partagés sont dans `dto/`, et
les services dans `services/` :

| Service | RPC | Notes |
| --- | --- | --- |
| AuthService | 11 | inscription, connexion, déconnexion, codes email, réinitialisation du mot de passe, OAuth |
| UserService | 16 | profil, préférences musicales, avatar, amis, blocages, recherche |
| MusicProviderService | 2 | get et search Deezer |
| PlaylistService | 19 | inclut le flux `WatchPlaylist` |
| EventService | 17 | inclut le flux `WatchEvent` |
| DelegationService | 6 | appareils, licences, enceinte de l'événement |

`buf generate` (config : `buf.gen.yaml` à la racine) produit, à partir de ces fichiers :
- les structs Go, les stubs gRPC et la passerelle REST, dans `backend/gen/go` ;
- les stubs Dart, dans `frontend/app/lib/gen` ;
- un fichier Swagger fusionné, que le backend sert sur `/docs/`.

Tous les fichiers proto partagent un seul package (`music_room.v1`), donc chaque message se retrouve dans un seul espace de noms Go et un seul espace de noms Dart.

Les dossiers générés sont **dans le gitignore**. Après un changement de proto ou de SQL, lancez `make generate`, ou
`make docker-generate` si les outils de l'hôte ne sont pas installés. Sinon le build échoue avec des erreurs « undefined ».

---

## 4. Backend

[Diagramme : backend](diagrams/walkthrough-backend.html)

### 4.1 Démarrage

`backend/cmd/main.go` fait tout le câblage, dans cet ordre :
1. Charger `.env`.
2. Lancer les migrations goose.
3. Ouvrir le pool pgx.
4. Se connecter à OpenFGA et fixer son modèle.
5. Construire l'outbox.
6. Construire la chaîne d'auth.
7. Démarrer le worker de l'outbox.
8. Construire le serveur gRPC avec ses intercepteurs.
9. Enregistrer les 6 services.
10. Démarrer les boucles d'arrière-plan des événements.
11. Servir le HTTP.

Si Postgres ou OpenFGA est absent, le backend s'arrête au démarrage.

Il y a deux listeners mais un seul jeu de handlers :
- **gRPC** sur `:50051`, avec la réflexion activée (pour que `grpcurl` fonctionne).
- **HTTP** sur `APP_HTTP_ADDR`. C'est `:8081` dans compose ; la valeur par défaut du code est `:8080`, qui entre en conflit avec l'image-service quand on lance les deux hors compose. Le côté HTTP sert :
  - l'API REST grpc-gateway, qui rappelle le port gRPC, donc le REST subit les mêmes contrôles ;
  - Swagger sur `/docs/` ;
  - les fichiers d'images sur `/media/` ;
  - la page de callback OAuth.

### 4.2 Pipeline de requête

[Diagramme : pipeline de requête](diagrams/walkthrough-request-pipeline.html)

Chaque appel passe par un intercepteur (`internal/interceptor/`). Voici les étapes, dans l'ordre :

1. **Limitation de débit.** Des token buckets en mémoire : un par IP (`APP_RATE_LIMIT_RPS`, 100 par défaut), et des limites par utilisateur plus strictes sur les actions sociales.
2. **Recherche de la politique.** `policy.go` a une entrée par RPC. **Une RPC sans entrée est refusée**, et un test fait échouer le build si une RPC en manque.
3. **Vérification de la session.** Le bearer token est haché et recherché dans `user_sessions`.
4. **Marquage de l'appelant.** Le champ appelant de la requête doit correspondre à la session ; l'id interne de l'utilisateur est ensuite rempli à partir de la session.
5. **Check OpenFGA** pour chaque exigence de la politique. Une lecture refusée renvoie `NotFound` ; une écriture refusée renvoie `PermissionDenied`.
6. **Résolution des ids.** Chaque `*_public_id` (UUID) est transformé en id interne `int64` et écrit dans la requête. L'objet qui a été vérifié est donc l'objet que le handler charge.
7. **Handler.** Il exécute les quelques contrôles que le graphe ne sait pas faire, appelés *contrôles résiduels* : rayon du lieu, événement terminé, licence de lecture.
8. **Journal d'activité.** Une ligne par appel, écrite en arrière-plan.

Les clients ne voient que des **UUID publics**. Les ids internes `BIGSERIAL` ne quittent jamais le serveur.

### 4.3 OpenFGA : les permissions comme un graphe

[Diagramme : OpenFGA](diagrams/walkthrough-openfga.html)

- **Le modèle.** `authz/model.fga` définit 6 types : `user`, `playlist`, `event`, `queue_entry`, `device`, `image`. Les rôles (owner, admin, editor, viewer) et les drapeaux publics sont des tuples stockés. Les permissions comme `can_view`, `can_edit_songs` et `can_vote` en sont calculées.
- **Postgres est la vérité, OpenFGA en est une copie.** Une écriture qui change l'accès appelle `outbox.InTx`. Dans la *même transaction*, elle écrit la ligne et les changements de tuples dus dans `openfga_tuple_outbox`. Après le commit, les changements sont appliqués immédiatement. Tout ce qui échoue est rejoué par un worker qui tourne toutes les 1 s dans compose (15 s par défaut). Une synchronisation échouée est un retard, jamais une écriture perdue.
- **Lectures.** L'intercepteur appelle `Check`. Les pages de liste (toutes les playlists, bibliothèque, événements) appellent `ListObjects(can_view)`, donc la liste *est* la réponse de permission.
- **Cache.** OpenFGA met les checks en cache 10 s, avec un cache controller, donc les réponses peuvent être périmées de quelques secondes. Le backend n'envoie `current_time` qu'aux permissions qui en ont besoin, arrondi à la minute, ce qui garde des clés de cache stables.
- **Pas dans le graphe :** le rayon du lieu (CEL n'a pas de géométrie), le statut de l'événement, et les licences de contrôle. Ce sont des contrôles en Go ou en SQL.
- **Déploiement.** `openfga-init` importe le modèle dans un store à identifiant fixe. `make fga-model` le réimporte.

Les règles en langage courant : `docs/annex/permissions.md`. Comment ajouter une nouvelle mutation : `docs/annex/authz-sync-guide.md`.

### 4.4 Auth et sessions

[Diagramme : auth et sessions](diagrams/walkthrough-auth.html)

- **Tokens de session opaques, pas des JWT.** La connexion crée 32 octets aléatoires. Le client les reçoit une seule fois, et le serveur ne stocke que le hash SHA-256 dans `user_sessions`. Révoquer une session est un seul `UPDATE`, donc il n'y a pas de refresh token.
- **Expiration.** Une session expire 30 jours après sa création, ou après 7 jours sans utilisation, et seulement si le compte est actif. Ces limites sont appliquées en Go. `last_used_at` avance au plus une fois par minute.
- **Les mots de passe** utilisent Argon2id.
- **Limites de connexion.** 5 échecs par email ou 20 par IP en 15 minutes, comptés dans `login_attempts`.
- **La vérification d'email et la réinitialisation du mot de passe** partagent des codes à 6 chiffres à usage unique (hachés, valables 15 min, 5 essais). Le mailer écrit dans les logs par défaut ; mettez `APP_MAILER=smtp` pour vraiment envoyer.
- **OAuth.** Le fournisseur redirige vers la page du backend `/oauth/callback`, qui renvoie le code vers `musicroom://oauth`. L'app appelle alors `OAuthLogin`, et le serveur échange le code lui-même.

### 4.5 Base de données : goose + sqlc

- **Migrations.** `backend/db/schema/` contient 23 migrations, embarquées dans le binaire et appliquées à chaque démarrage. Elles doivent rester **à plat** : `//go:embed schema/*.sql` comme `goose.Up` ignorent les sous-dossiers.
- **Requêtes.** `backend/db/query/*.sql` sont écrites à la main ; `sqlc generate` les transforme en Go typé dans `backend/db/sqlc/`. Les commentaires des fichiers de requêtes expliquent *pourquoi* chaque requête a sa forme.

---

## 5. Temps réel

[Diagramme : temps réel](diagrams/walkthrough-realtime.html)

Les écrans en direct utilisent des **flux serveur gRPC** : `WatchPlaylist` et `WatchEvent`.

1. Une écriture est validée, **puis** publie un signal sur son topic (`playlist:<id>` ou `event:<id>`) dans un hub
   en mémoire (`internal/realtime/hub.go`).
2. Le signal ne transporte **aucune donnée**. Chaque flux ouvert se réveille et relit l'état complet **pour son propre spectateur**,
   donc les champs propres à chaque spectateur comme `viewer_can_vote` restent corrects. Une rafale d'écritures devient une seule relecture.
3. Chaque flux revérifie aussi `can_view` toutes les 5 s, et se termine avec `NotFound` si l'accès a disparu.
4. Des boucles d'arrière-plan publient aussi :
   - les minuteurs d'enchaînement automatique (morceau suivant quand un morceau se termine) ;
   - la fin d'événement (toutes les 10 s) ;
   - la vérification de présence de l'hôte (mettre la lecture en pause si le téléphone de l'hôte cesse de regarder pendant 5 s).

**Limite :** le hub fonctionne dans un seul processus. Faire tourner plusieurs backends demanderait du pub/sub Redis.

---

## 6. Frontend (Flutter)

[Diagramme : frontend](diagrams/walkthrough-frontend.html)

### 6.1 Démarrage et câblage

`frontend/app/lib/main.dart` fait ceci dans l'ordre :
1. Charger les infos de l'appareil et l'adresse du backend enregistrée.
2. Ouvrir **un seul canal gRPC** avec deux intercepteurs : métadonnées client, puis auth.
3. Construire une source par service du backend.
4. Restaurer la session.
5. Démarrer les stores globaux (session, utilisateur courant, appareil).
6. Appeler `runApp`.

La session est restaurée avant que le routeur existe, donc la première redirection du routeur est déjà correcte.

Tout est transmis avec `provider`. Chaque source est fournie sous des **petites interfaces**
(`EventApi`, `LiveEventApi`, ...), donc une page et son faux de test ne voient que les appels que cette page utilise.

### 6.2 Le chemin des données

```
Widget  →  page Store  →  Source (interface)  →  Command  →  client gRPC généré
```

- **Command** (`core/commands/`) : une minuscule classe par RPC. Son `call()` transforme `GrpcError` en un `AppError` typé, donc aucun type gRPC ne fuit au-dessus de la couche de données.
- **Source** (`features/*/data/*_source.dart`) : construit les requêtes et convertit les DTO en modèles du domaine de `core/models/`, avec `core/mapping/`.
- **Store** (`features/*/presentation/stores/`) : contient `ValueNotifier<ItemState<T>>` ou `ListState<T>`. Les widgets se reconstruisent avec `ValueListenableBuilder`.
- **Placement des stores.** Les stores globaux vivent dans `main.dart`. Tous les autres stores sont **créés et détruits par leur page**. La seule exception est `SongPlayer`, qui est global à l'app pour que la musique continue entre les onglets.
- **Erreurs.** Le mixin `BusyState` exécute une action à la fois et affiche un message propre à la fonctionnalité pour chaque type d'`AppError`.

### 6.3 Écrans en direct

`LiveStream` (`core/sources/live_stream.dart`) garde un flux Watch ouvert tant qu'une page est visible :
- il se reconnecte après 1, 2, 5, puis 10 s ;
- un `NotFound` l'arrête (l'objet a été supprimé ou rendu privé).

Un appui sur un bouton affiche tout de suite la réponse propre de la RPC, et la poussée suivante est cohérente avec elle.

### 6.4 Auth côté client

- **Le token.** `SessionCredentials` le garde en mémoire ; `flutter_secure_storage` le garde sur disque.
- **L'intercepteur.** `AuthInterceptor` ajoute `authorization: Bearer` à chaque appel sauf les appels d'auth anonymes. Sur `UNAUTHENTICATED`, la session se termine.
- **Navigation.** `SessionStore` pilote le routeur via `authRedirect` : déconnecté va vers `/login`, un email non vérifié va vers `/verify-email`.

### 6.5 Présent mais non branché

Ces éléments existent dans le code, mais rien ne les utilise pour l'instant :
- Les classes de base `DomainSource` et `Repository`, et la plupart de `features/music/song/`. Le seul vrai repository est `SessionRepository`.
- Le chemin web/REST : `HttpService`, `HttpSource`, et l'export conditionnel dans `core/network/network.dart`. L'app est en gRPC natif uniquement.

---

## 7. Les trois services

### 7.1 Track Vote

[Diagramme : Track Vote](diagrams/walkthrough-track-vote.html)

- **Qui peut voter.** La licence de vote de l'événement est `everyone`, `invited_only` ou `location_time`. Dans OpenFGA, elle devient exactement l'un de `open_vote`, `invited_vote` ou `window_vote`. Proposer un morceau utilise la même permission que voter.
- **`location_time`.** OpenFGA vérifie la fenêtre horaire quotidienne, avec une condition CEL. Go vérifie ensuite le rayon du lieu et que l'événement n'est pas terminé.
- **Un vote est une seule instruction SQL** (`CastQueueVote`). Elle verrouille l'entrée tant qu'elle est en file, insère le vote avec `ON CONFLICT DO NOTHING` (un vote par personne), et ajoute 1 à `vote_count`. Il n'y a pas de boucle de nouvelle tentative.
- **Ordre de la file.** Il n'y a pas de colonne de position : la file est triée par `vote_count DESC, score_reached_at`, donc une égalité revient au morceau qui a atteint ce nombre en premier.
- **Lecture.**
  - `playNext` verrouille la ligne de lecture, démarre l'entrée du haut, et passe l'événement en `live` à la première lecture.
  - Un minuteur serveur joue le morceau suivant quand un morceau se termine.
  - Seul l'hôte, ou un ami délégué, peut contrôler la lecture.
- **Temps réel.** Chaque changement réveille `WatchEvent`. L'app ne joue le son que sur le téléphone enceinte.

### 7.2 Playlist Editor

[Diagramme : Playlist Editor](diagrams/walkthrough-playlist-editor.html)

- **Qui peut modifier.** La règle d'édition est `owner or admin or editor or (can_view and open_edit)`. Une playlist privée n'est jamais modifiable par des inconnus, même avec la licence `everyone`.
- **Chaque modification de morceau est une transaction, dans un ordre fixe :**
  1. `BumpPlaylistRevision` prend le verrou de la ligne de la playlist et renvoie la nouvelle révision.
  2. Le changement lui-même.
  3. `AppendPlaylistOp` écrit l'opération à cette révision.

  Le verrou fait attendre son tour aux éditeurs concurrents. Les révisions sont donc sans trou, et deux personnes qui ajoutent le même morceau ne peuvent pas passer toutes les deux le contrôle de doublon.
- **Déplacer un morceau.** Les positions sont des `NUMERIC`, donc un morceau déplacé se place à mi-chemin entre ses voisins et rien n'est jamais renuméroté.
- **Réglages.** Les changements de visibilité, de licence et de membres changent aussi des tuples OpenFGA, donc ils passent par l'outbox.
- **Dans l'app.** L'éditeur ignore tout état poussé plus ancien que la révision qu'il affiche déjà.

### 7.3 Control Delegation

[Diagramme : Control Delegation](diagrams/walkthrough-control-delegation.html)

- **Appareils.** Chaque téléphone s'enregistre comme appareil à chaque session, et sa session lui est rattachée. Le téléphone de l'hôte devient l'**enceinte** de l'événement la première fois que l'hôte lance la lecture.
- **Octroi.** Le propriétaire de l'appareil enceinte peut donner à un **ami** une licence pour **un seul événement**. Une licence signifie le contrôle de tout le lecteur : lecture, pause, déplacement dans le morceau, passage au suivant.
- **Les licences sont des lignes SQL** (`device_control_licenses`), pas des tuples OpenFGA. `canControlPlayback` autorise toujours l'hôte ; toute autre personne a besoin d'une licence active pour cet événement sur l'appareil enceinte.
- **Révocation.**
  - Révoquer renseigne `revoked_at` et garde la ligne, comme piste d'audit.
  - Retirer un ami ou le bloquer révoque tous les octrois entre les deux utilisateurs.
  - Déplacer l'enceinte vers un autre appareil déplace ses licences avec elle.
- **Temps réel.** Chaque changement de licence réveille `WatchEvent`, donc les contrôles de l'ami apparaissent ou disparaissent immédiatement.

---

## 8. Modèle de données

[Diagramme : modèle de données](diagrams/walkthrough-data-model.html)

Il y a 28 tables, regroupées par domaine. `docs/annex/data-model.md` est la référence complète : lisez-le avant de
modifier du SQL.

| Domaine | Tables principales |
| --- | --- |
| Identité | `users`, `user_sessions`, `devices`, `user_oauth_accounts`, `user_tokens`, `login_attempts` |
| Profil / médias | `user_profiles`, `user_music_preferences`, `images` |
| Social | `friend_requests`, `friendships`, `user_blocks` |
| Catalogue | `songs` (un cache des morceaux Deezer) |
| Playlists | `playlists`, `playlist_members`, `playlist_invitations`, `playlist_songs`, `playlist_ops` |
| Événements | `events`, `event_members`, `event_invitations`, `event_queue_entries`, `event_queue_votes`, `event_playback_states`, `event_ops` |
| Délégation | `device_control_licenses` |
| Audit / synchronisation | `activity_logs` (partitionnée par mois), `openfga_tuple_outbox` |

Conventions :
- **Ids.** Un `BIGSERIAL id` sert aux jointures ; un `public_id UUID` est le seul id qui quitte le serveur.
- **Suppression logique.** Les playlists et les événements renseignent `deleted_at`, et les lectures filtrent dessus.
- **Amitiés.** Stockées une fois par paire, avec le plus petit id en premier (`CHECK (user_a_id < user_b_id)`).

---

## 9. Exécution et tests

Tout passe par le `Makefile` à la racine (`make help`).

| Objectif | Commande |
| --- | --- |
| Stack complète dans Docker | `make all` |
| Éval : stack + données de démo + téléphone | `make eval` |
| Le « téléphone » dans un navigateur | `make phone` (`:6080`), `make phone-2` (`:6081`) |
| APK Android pour un vrai téléphone | `make apk` |
| Régénérer le code | `make generate`, ou `make docker-generate` sans les outils de l'hôte |
| Tests Go | `make backend-test` |
| Tests d'API (pytest, REST boîte noire) | `make docker-api-test` |
| Test de charge (k6) | `make loadtest SCENARIO=mixed LT_PROFILE=small` |

- **Le « téléphone » de l'éval.** Les machines d'éval n'ont pas de `/dev/kvm`, donc aucun émulateur Android ne peut tourner. Le « téléphone » est le build **Linux** de Flutter tournant sur Xvfb et affiché dans le navigateur via noVNC (`frontend/phone/`). Il emprunte le même chemin gRPC natif qu'Android. Le son et le GPS sont relayés par de petits utilitaires.
- **Tests d'API.** La suite de `tests/` est découpée par fonctionnalité (`auth/`, `user/`, `playlist_editor/`, `track_vote/`, `control_delegation/`).
- **Tests de charge.** Après une exécution, `loadtest/verify/verify.py` vérifie que la base est restée cohérente : révisions sans trou, nombres de votes égaux aux lignes de vote, et au plus une licence active. Détails dans `docs/annex/load-testing.md`.

---

## 10. Lacunes connues et docs périmées

Vérifié par rapport au code le 2026-10-25 :

- **Redis** tourne dans compose (et le backend attend qu'il soit sain), mais le backend ne s'y connecte plus. Le hub temps réel et les limites de débit tournent en mémoire.
- **`event_ops`** existe comme table, mais rien n'y écrit.
- **`ListPlaylistOpsSince`** fonctionne côté serveur, mais l'app ne l'appelle jamais. À la reconnexion, l'app relit toute la playlist.
- **Le client web/REST** (§6.5) n'est pas branché. `HttpService` construit aussi son URL avec le port gRPC, ce qui ressemble à un bug.
- **Docs périmées :**
  - `docs/annex/permissions.md` §14 et les lignes de licence de `docs/annex/data-model.md` §14 décrivent encore des drapeaux de licence par action et des tuples de licence. La migration `00023` et `authz/model.fga` ont supprimé les deux.
  - `docs/permissions-branch.md` est une trace de la branche `permissions` telle qu'elle était : ses notes sur `/ws` et les tests rouges sont de l'histoire, pas l'état actuel.
  - Le dossier `frontend/packages/` (chihuahua, protoc-gen-commands) a été supprimé le 2026-10-19.

---

## 11. Pour aller plus loin

| Fichier | Sujet |
| --- | --- |
| [`[FR]_tech-choices.md`](%5BFR%5D_tech-choices.md) | Pourquoi chaque outil a été choisi, avec avantages, inconvénients et alternatives |
| [`who-did-what.md`](who-did-what.md) | Qui a construit quelle partie, d'après l'historique git |
| `docs/annex/data-model.md` | Chaque table, les règles de concurrence (§13), la correspondance OpenFGA (§14) |
| `docs/annex/permissions.md` | Les règles de permission en langage courant, plus les contrôles résiduels en Go |
| `docs/annex/authz-enforcement.md` | Le côté lecture : intercepteur et politiques |
| `docs/annex/authz-sync-guide.md` / `docs/annex/authz-sync-summary.md` | Le côté écriture : garder OpenFGA synchronisé |
| `docs/annex/auth-client.md` | Comment l'app garde une session ; configuration OAuth |
| `docs/annex/load-testing.md` | Méthode et résultats des tests de charge |
| `docs/annex/todo.md` | Ce qu'il reste à faire par rapport au sujet |
| `docs/annex/project-state.md` | Ancien instantané de l'état du projet |
