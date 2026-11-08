# Choix technologiques

Les technologies et frameworks utilisés par le projet, et pourquoi. Chaque entrée a une courte description,
puis les avantages, les inconvénients, la raison de notre choix, et ce que nous aurions pu utiliser à la place.

## Contrat et API

### Protobuf + buf

Une façon de définir des messages et des services indépendante du langage. Un générateur écrit ensuite
le code pour chaque langage. On décrit seulement les données et les méthodes.
- Les 13 fichiers `.proto` de `proto/music_room/v1/` partagent un seul package, `music_room.v1`. Ils définissent
  6 services : Auth, User, MusicProvider, Playlist, Event, Delegation.
- `buf` vérifie le style des fichiers (lint), détecte les changements incompatibles par rapport à `main`, et lance les générateurs. Une seule exécution
  écrit les structs Go, les stubs gRPC et la passerelle REST pour le backend, les stubs Dart pour l'app,
  et la spec Swagger.

| | |
| --- | --- |
| **Avantages** | Des interfaces typées des deux côtés à partir d'un seul fichier. On peut ajouter des champs sans casser les anciens clients, car les champs sont identifiés par un numéro. Fonctionne avec n'importe quel langage ou plateforme. |
| **Inconvénients** | Le format binaire n'est pas lisible par un humain. Il faut une chaîne d'outils de génération de code, et les dossiers générés sont dans le gitignore : un clone neuf ou un changement de proto demande d'abord `make generate`. |
| **Pourquoi ce choix** | C'est le choix naturel avec gRPC. Une modification d'un fichier proto met à jour le serveur, l'app et la doc de l'API, ce qui évite beaucoup de code écrit à la main. |
| **Alternatives** | OpenAPI/JSON Schema écrit à la main, schémas GraphQL, ou modèles JSON écrits à la main de chaque côté. |

### gRPC

RPC = Remote Procedure Call (appel de procédure distante). Le client appelle une méthode du serveur comme s'il s'agissait d'une fonction locale.
gRPC envoie des messages protobuf sur HTTP/2.
- L'app utilise des appels unaires pour les requêtes normales et des flux serveur pour les mises à jour en direct
  (`WatchPlaylist`, `WatchEvent`).

| | |
| --- | --- |
| **Avantages** | Rapide et compact. Clients typés générés en Go et en Dart. Le streaming est intégré. La réflexion permet à `grpcurl` d'appeler le serveur sans stubs. |
| **Inconvénients** | Les navigateurs ne peuvent pas l'appeler directement, donc une passerelle REST est nécessaire. Plus difficile à inspecter que du JSON (il faut `grpcurl`). La limite par défaut de 4 MiB par message a dû être relevée pour l'envoi des avatars. |
| **Pourquoi ce choix** | Un seul contrat donne à la fois le serveur Go et le client Dart, et les flux serveur nous donnent du temps réel sans protocole WebSocket séparé. Le REST et le Swagger demandés par le sujet viennent de grpc-gateway, donc nous ne les perdons pas.<br>Note : le backend parle à OpenFGA en **HTTP**, pas en gRPC (SDK Go). Le passage à gRPC est listé comme travail futur possible dans `docs/annex/load-testing.md`. |
| **Alternatives** | REST/JSON avec un WebSocket pour les données en direct, GraphQL avec subscriptions, Connect RPC. |

### grpc-gateway + Swagger

Un reverse proxy généré qui transforme les appels REST/JSON en appels gRPC. Les routes REST sont déclarées
sous forme d'annotations dans les fichiers proto.
- Il tourne dans le même processus Go sur `:8081` et appelle le port gRPC en loopback, donc le REST passe par
  les mêmes handlers et les mêmes contrôles de permissions.
- Swagger UI est servi par le backend sur `/docs/`, à partir de la spec générée par buf.
- Utilisé par la suite pytest et les tests de charge k6, ou par d'éventuels clients web. L'app elle-même utilise gRPC.

| | |
| --- | --- |
| **Avantages** | REST et documentation de l'API gratuits, rien n'est implémenté deux fois. |
| **Inconvénients** | Une couche générée de plus. Il ne transmet que certains en-têtes HTTP (les en-têtes personnalisés demandent le préfixe `Grpc-Metadata-` ou un matcher personnalisé). Le nommage des champs JSON et les valeurs par défaut diffèrent légèrement de protobuf. |
| **Pourquoi ce choix** | Le sujet préfère du REST avec une documentation générée. Cela y répond sans renoncer à gRPC. |
| **Alternatives** | Une couche REST écrite à la main, Connect RPC (sert gRPC et JSON sur un même port), le transcodeur gRPC-JSON d'Envoy. |

## Backend

### Go

Le langage du backend. Un seul binaire sert gRPC, REST, Swagger, les images et le callback OAuth.

| | |
| --- | --- |
| **Avantages** | Langage simple, compilation rapide, un seul binaire statique (l'image est distroless). Les goroutines rendent les flux et les workers en arrière-plan peu coûteux. Support gRPC de premier ordre. |
| **Inconvénients** | Gestion d'erreurs verbeuse, moins de bibliothèques de haut niveau que Java ou Node. Pas d'exceptions ni de patterns riches en génériques, donc une partie du code est répétitive. |
| **Pourquoi ce choix** | Bon choix pour un serveur gRPC avec beaucoup de flux concurrents, et facile à lire pour toute l'équipe (un passé C/C++ commun aux 4 membres). |
| **Alternatives** | Node.js/TypeScript, Java/Kotlin avec Spring, Rust, Python (FastAPI). |

### PostgreSQL 16 + pgx

La base de données principale, accessible via le driver `pgx` et son pool de connexions.
- Nous utilisons beaucoup de fonctionnalités propres à Postgres : emails `citext`, enums natifs, `jsonb`, positions
  `NUMERIC`, index uniques partiels, partitions mensuelles pour `activity_logs`, verrous de ligne et
  `FOR UPDATE SKIP LOCKED` pour l'outbox.

| | |
| --- | --- |
| **Avantages** | Transactions et contraintes solides, donc de nombreuses règles sont garanties par la base elle-même. Mature et bien connu. Familiarité des membres de l'équipe. |
| **Inconvénients** | Un service de plus à faire tourner. Certaines règles ne peuvent pas être en SQL (`NOW()` est interdit dans un `CHECK`), donc elles vivent en Go. |
| **Pourquoi ce choix** | Les trois services ont besoin d'écritures concurrentes qui restent correctes (votes, modifications de playlist). Postgres l'assure avec un simple `READ COMMITTED` et des verrous de ligne. |
| **Alternatives** | MySQL/MariaDB, SQLite, MongoDB. |

### sqlc

Un outil qui transforme du SQL écrit à la main en code Go.
- On écrit le schéma et les requêtes en SQL (`backend/db/query/*.sql`).
- sqlc génère des structs Go pour les tables et une méthode Go typée par requête.

| | |
| --- | --- |
| **Avantages** | Contrôle total de chaque requête, et le code Go reste typé. Les requêtes sont vérifiées par rapport au schéma à la génération. |
| **Inconvénients** | Il faut écrire du SQL, une compétence différente du code orienté objet. Le code généré est dans le gitignore et doit être régénéré. Certains types demandent des surcharges (`citext`, `inet`), et les partitions sont cachées dans un bloc `DO` pour que sqlc ne crée pas 25 faux modèles. |
| **Pourquoi ce choix** | Certaines fonctionnalités ont des problèmes de concurrence (votes, révisions de playlist) qui demandent du SQL exact : verrous de ligne, ordre fixe des instructions, `SKIP LOCKED`. Un ORM cache ces requêtes. Les transactions elles-mêmes sont ouvertes en Go (`pool.Begin`). |
| **Alternatives** | Un ORM (GORM, ent), `pgx` brut avec lecture des lignes à la main, sqlx, Jet. |

### goose

Un outil de migration. Chaque changement de schéma est un fichier SQL numéroté dans `backend/db/schema/`.
- Les fichiers sont embarqués dans le binaire à la compilation (`//go:embed`) et appliqués au démarrage
  du backend (`goose.Up` dans `main.go`).
- Les 23 migrations sont en SQL. goose gère aussi les migrations en Go, mais nous n'en utilisons pas.

| | |
| --- | --- |
| **Avantages** | Des fichiers SQL simples, pas d'étape de migration séparée à penser à lancer. Une base neuve est prête dès que le backend démarre. |
| **Inconvénients** | • Le dossier doit rester plat : les fichiers dans des sous-dossiers sont ignorés silencieusement.<br>• Écrire une annotation `+goose` dans un commentaire casse le fichier.<br>• Modifier une ancienne migration ne fait rien sur les bases existantes. |
| **Pourquoi ce choix** | Simple, orienté SQL, et compatible avec `go:embed`, donc le binaire porte son propre schéma. |
| **Alternatives** | Golang-migrate, Atlas, tern. |

### OpenFGA

Un serveur de permissions ReBAC (Relationship-Based Access Control, contrôle d'accès basé sur les relations).
- Le modèle (`authz/model.fga`) définit des types (user, playlist, event, queue entry, device, image)
  et comment les permissions découlent des relations, par exemple
  `can_edit_songs: owner or admin or editor or (can_view and open_edit)`.
- Nous écrivons des tuples (« l'utilisateur X est éditeur de la playlist Y ») dérivés de nos lignes Postgres. OpenFGA parcourt
  le graphe pour répondre à un `Check` (« X peut-il modifier Y ? ») ou à un `ListObjects` (« quelles playlists X peut-il voir ? »).
- Chaque RPC est vérifiée dans l'intercepteur. Les tuples sont gardés synchronisés par un outbox transactionnel.

| | |
| --- | --- |
| **Avantages** | Les règles de permission sont dans un seul fichier lisible. Un changement se propage automatiquement (on retire un ami, et chaque droit issu de l'amitié disparaît aussi). Il remplace des contrôles Go/SQL dispersés. |
| **Inconvénients** | • Ce fut le **premier goulot d'étranglement** sous charge (limité par le CPU).<br>• Le cache des checks rend un `Check` périmé de 1 à 2 s après une révocation.<br>• Il a besoin de son propre Postgres.<br>• Le garder synchronisé avec notre base demande un outbox et un worker.<br>• Les conditions en Common Expression Language (CEL) de Google ne savent pas faire de géographie, donc le contrôle du rayon du lieu reste en Go. |
| **Pourquoi ce choix** | Parfait pour une app collaborative, où l'accès vient de la propriété, de l'appartenance, de l'amitié et des licences plutôt que de rôles fixes. |
| **Alternatives** | Contrôles en Go/SQL, SpiceDB, Casbin, OPA, Permify. |

### Tokens de session opaques (pas de JWT)

La connexion renvoie un token aléatoire de 32 octets. Le serveur ne stocke que son hash SHA-256 dans `user_sessions`
et le recherche à chaque requête.

| | |
| --- | --- |
| **Avantages** | La déconnexion et la révocation prennent effet à la requête suivante. Pas de refresh tokens, pas de rotation, pas de clés de signature. |
| **Inconvénients** | Une lecture en base par requête authentifiée. |
| **Pourquoi ce choix** | Un JWT signé ne peut pas être révoqué avant son expiration, et la séparation access/refresh n'existe que pour contourner cela. Une lecture indexée est peu coûteuse à notre échelle. |
| **Alternatives** | Tokens JWT access + refresh, PASETO. |

### Argon2id

Hachage des mots de passe (`golang.org/x/crypto/argon2`, 64 MiB de mémoire, format de chaîne PHC).

| | |
| --- | --- |
| **Avantages** | Meilleure pratique actuelle, résistant au cassage par GPU. |
| **Inconvénients** | Chaque connexion coûte 64 MiB de mémoire et du vrai CPU, ce qui compte dans les tests de charge. |
| **Pourquoi ce choix** | Recommandé par l'OWASP pour les nouveaux projets. |
| **Alternatives** | Bcrypt, scrypt, PBKDF2. |

### OAuth (Google, 42)

Connexion sociale, écrite à la main contre les URL de token et d'informations utilisateur de chaque fournisseur. Le fournisseur
redirige vers `/oauth/callback` du backend, qui renvoie le code à l'app
(`musicroom://oauth`).

| | |
| --- | --- |
| **Avantages** | Aucune bibliothèque en plus, et les particularités de chaque fournisseur tiennent dans un petit fichier. Les fournisseurs sans client ID sont simplement désactivés. |
| **Inconvénients** | Chaque fournisseur doit être enregistré à la main. Pas encore de PKCE. |
| **Pourquoi ce choix** | Le sujet demande une connexion sociale. Les deux fournisseurs ont des flux similaires. Un fournisseur Facebook est écrit aussi, mais aucune app développeur Meta n'a pu être enregistrée, donc l'app ne l'affiche pas. |
| **Alternatives** | `golang.org/x/oauth2`, un service d'identité (Keycloak, Auth0, Firebase Auth). |

### Temps réel : hub en mémoire + flux gRPC

Après chaque écriture, un service envoie un signal vide sur un topic (`playlist:<id>`, `event:<id>`). Chaque
flux `Watch` ouvert sur ce topic relit l'état complet et le pousse vers son téléphone.

| | |
| --- | --- |
| **Avantages** | Le signal ne transporte aucune donnée, donc il ne peut pas être périmé. Une rafale d'écritures devient une seule relecture. Pas de protocole en plus : c'est la même connexion gRPC. |
| **Inconvénients** | Le hub vit en mémoire, donc il ne fonctionne qu'avec un seul processus backend. Les flux revérifient les permissions toutes les 5 s plutôt qu'instantanément. |
| **Pourquoi ce choix** | La chose la plus simple qui fonctionne pour un seul serveur. |
| **Alternatives** | WebSockets, Server-Sent Events, Redis pub/sub ou Postgres `LISTEN/NOTIFY` pour plusieurs processus backend. |

### Limitation de débit (en mémoire)

Des token buckets de `golang.org/x/time/rate` : par IP sur chaque appel, et par utilisateur sur les routes sociales.
Les connexions ont leur propre limite, comptée dans Postgres.

| | |
| --- | --- |
| **Avantages** | Aucune dépendance, très peu coûteux. |
| **Inconvénients** | Les compteurs sont par processus et repartent à zéro au redémarrage. Le test de charge doit les désactiver, car k6 envoie tout depuis une seule IP. |
| **Pourquoi ce choix** | Il n'y a qu'un backend, donc un compteur partagé n'est pas encore nécessaire. |
| **Alternatives** | Compteurs Redis, une limite sur un reverse proxy (nginx, Envoy). |

### Redis

Un magasin clé-valeur en mémoire. Il tourne dans Docker Compose, mais **le backend ne s'y connecte
plus** et rien n'y est stocké.

| | |
| --- | --- |
| **Avantages** | Serait l'endroit naturel pour un cache de sessions, du pub/sub entre processus, ou des limites de débit partagées. |
| **Inconvénients** | Un service de plus qui n'a rien à faire aujourd'hui. |
| **Pourquoi ce choix** | Gardé pour plus tard. `docs/annex/data-model.md` §5 liste ce qui passerait sur Redis, dans l'ordre, et dit que le déclencheur est une mesure, pas une préférence. |
| **Alternatives** | Postgres seul (ce que nous faisons maintenant), Valkey, Memcached. |

### API Deezer

Le catalogue de chansons. La recherche passe par l'API publique de Deezer, et un morceau est copié dans notre table `songs`
la première fois qu'une playlist ou une file l'utilise.

| | |
| --- | --- |
| **Avantages** | Gratuite, sans clé d'API, et elle fournit des liens d'extraits de 30 secondes que l'app peut lire. |
| **Inconvénients** | Seulement des extraits de 30 secondes, les liens d'extraits expirent après 15 minutes, et les erreurs reviennent en HTTP 200 et doivent être vérifiées à la main. |
| **Pourquoi ce choix** | De l'audio lisible sans compte, sans clé et sans processus de validation. |
| **Alternatives** | Spotify (demande OAuth et Premium pour la lecture), Apple Music, Jamendo, SoundCloud. |

### Service d'images (Rust, axum)

Un petit service sans état qui redimensionne les avatars et les pochettes (`POST /resize`). Le backend stocke les
fichiers lui-même et les sert sur `/media/`.

| | |
| --- | --- |
| **Avantages** | Minuscule, rapide, isolé : une mauvaise image ne peut pas faire tomber le backend principal. |
| **Inconvénients** | Un second langage et un second service. La limite de taille doit être cohérente à trois endroits. |
| **Pourquoi ce choix** | Le décodage d'images consomme beaucoup de CPU et est autonome : un bon travail pour un petit service Rust séparé. |
| **Alternatives** | Redimensionner en Go (package `image`, `disintegration/imaging`), libvips, un CDN d'images. |

## Frontend

### Flutter / Dart

Un framework d'interface. Dart est compilé en code natif, et Flutter dessine sa propre interface, donc un seul code tourne
sur mobile et sur desktop.
- Les builds que nous utilisons : Android (APK), Linux (le « téléphone » de l'éval), et macOS/iOS pendant le développement.
  Le build web n'est pas utilisé.

| | |
| --- | --- |
| **Avantages** | Un seul code pour toutes les plateformes, hot reload, le même rendu partout. |
| **Inconvénients** | Dart est un langage moins courant. Les fonctions natives (trousseau, audio, webview) demandent des plugins, et certains ont des lacunes sur Linux. |
| **Pourquoi ce choix** | Une seule app pour Android et iOS, plus un build desktop qui tourne sur les machines d'éval sans émulateur. |
| **Alternatives** | React Native, Kotlin Multiplatform, Swift + Kotlin natifs. |

### grpc-dart

Le client gRPC Dart, avec des stubs générés à partir des mêmes protos que le backend.
- `AuthInterceptor` ajoute `authorization: Bearer` à chaque appel. `LiveStream` garde les flux `Watch`
  ouverts et les reconnecte.

| | |
| --- | --- |
| **Avantages** | Appels typés sans modèles JSON écrits à la main. Le même streaming que le serveur. |
| **Inconvénients** | Les intercepteurs appartiennent à chaque client généré, pas au canal, donc chaque client doit être construit avec eux. |
| **Pourquoi ce choix** | C'est la conséquence du choix de gRPC. |
| **Alternatives** | REST via le client OpenAPI généré (il existe, mais n'est pas utilisé), grpc-web. |

### provider + stores ValueNotifier

`provider` transmet les objets partagés (réseau, stores, interfaces d'API) le long de l'arbre de widgets. Chaque store
de fonctionnalité garde son état dans des `ValueNotifier` que les widgets écoutent.

| | |
| --- | --- |
| **Avantages** | Petit, construit sur les primitives propres de Flutter, facile à tester avec de fausses API. |
| **Inconvénients** | Plus de câblage manuel qu'avec de plus gros frameworks. Libérer les flux est le travail du store. |
| **Pourquoi ce choix** | Simple et bien documenté, et suffisant pour la taille de l'app. |
| **Alternatives** | Riverpod, Bloc, GetX, MobX. |

### go_router

Routage déclaratif. `authRedirect` envoie un utilisateur déconnecté vers `/login` et un utilisateur non vérifié vers
`/verify-email`, et se relance à chaque changement de session.

| | |
| --- | --- |
| **Avantages** | Les routes au même endroit, les redirections sous forme d'une fonction simple facile à tester. |
| **Inconvénients** | Le routeur doit être construit une seule fois : le reconstruire réinitialise la pile de navigation. |
| **Pourquoi ce choix** | Le package de routage maintenu par l'équipe Flutter. |
| **Alternatives** | Navigator 2.0 à la main, auto_route, beamer. |

### flutter_secure_storage

Stocke le token de session, l'utilisateur connecté et l'identifiant d'appareil de l'installation dans le trousseau du système
(Keychain sur iOS/macOS, Keystore sur Android, libsecret sur Linux).

| | |
| --- | --- |
| **Avantages** | Le token ne se trouve jamais dans des fichiers en clair. |
| **Inconvénients** | Comportement différent selon la plateforme. Sur Linux, il faut un trousseau déverrouillé, que le conteneur du téléphone doit mettre en place. |
| **Pourquoi ce choix** | Le plugin Flutter standard pour les secrets. |
| **Alternatives** | Shared_preferences (non chiffré), Hive avec chiffrement. |

### flutter_web_auth_2 (+ webview patchée)

Ouvre la page de connexion du fournisseur et capte la redirection vers l'app.
- Sur Linux, la fenêtre de connexion est la webview propre à l'app, issue d'une copie patchée de
  `desktop_webview_window` dans `frontend/app/third_party/` (la version d'origine plantait à la fermeture).

| | |
| --- | --- |
| **Avantages** | Un seul flux OAuth pour toutes les plateformes. |
| **Inconvénients** | Nous maintenons un plugin patché. |
| **Pourquoi ce choix** | Le plugin OAuth Flutter le plus complet, desktop compris. |
| **Alternatives** | Flutter_appauth (pas de desktop), un flux webview fait maison. |

### just_audio + media_kit

Lit les extraits Deezer de 30 secondes, pour les playlists comme pour la lecture des événements.
- just_audio n'a pas de backend Linux, donc `just_audio_media_kit` (libmpv) comble ce manque.

| | |
| --- | --- |
| **Avantages** | Une seule API audio sur toutes les plateformes. |
| **Inconvénients** | Une bibliothèque native de plus sur Linux, et certains états (fin de piste) s'y comportent différemment. |
| **Pourquoi ce choix** | Le lecteur audio Flutter le plus utilisé. |
| **Alternatives** | Audioplayers, media_kit seul. |

### flutter_map + OpenStreetMap + geolocator

La carte du lieu et la position du téléphone, utilisées pour les événements où seules les personnes présentes sur place peuvent voter.

| | |
| --- | --- |
| **Avantages** | Tuiles gratuites sans clé d'API. Sur le téléphone Linux, la position vient d'un fichier que la page du navigateur renseigne. |
| **Inconvénients** | Les tuiles demandent Internet. La politique de tuiles d'OSM exige un vrai user-agent. |
| **Pourquoi ce choix** | Pas de clé et pas de compte de facturation. |
| **Alternatives** | Google_maps_flutter, Mapbox. |

## Exécution et tests

### Docker + Compose + Makefile

Tout tourne dans des conteneurs, lancés par le `Makefile` à la racine (`make eval`, `make all`, …).
- La stack : Postgres, Redis, OpenFGA avec son propre Postgres, le backend, le service d'images, et
  des profils optionnels pour le téléphone et Android.
- Des Dockerfiles multi-étapes compilent le code dans les images, génération de code comprise.

| | |
| --- | --- |
| **Avantages** | Les machines d'éval n'ont besoin que de Docker et de `make`. Une seule commande lance tout. |
| **Inconvénients** | Grosses images et premiers builds longs. Les machines à faible espace disque demandent des cibles spéciales. |
| **Pourquoi ce choix** | Les machines d'éval ont Docker et rien d'autre. |
| **Alternatives** | Installer les outils sur l'hôte, Nix, Kubernetes (trop pour ce projet). |

### Le « téléphone » (build Linux dans le navigateur)

Le build Linux de Flutter tourne dans un conteneur sur Xvfb et s'affiche dans le navigateur via noVNC
(`:6080`). Le son et la position sont aussi relayés vers la page.

| | |
| --- | --- |
| **Avantages** | Fonctionne sur des machines sans `/dev/kvm`. Utilise le même chemin gRPC natif qu'Android. |
| **Inconvénients** | Ce n'est pas un vrai téléphone : rendu logiciel, un trousseau à déverrouiller, pas de vrai GPS. |
| **Pourquoi ce choix** | Un émulateur Android ne peut pas démarrer sans `/dev/kvm`. `make apk` fournit quand même un APK pour un vrai téléphone, et `make android` lance un émulateur là où KVM existe. |
| **Alternatives** | Un émulateur Android (demande KVM), un vrai téléphone sur le réseau local, le build web. |

### k6 (tests de charge)

Un outil de test de charge dont les scénarios sont écrits en JavaScript (`loadtest/`).
- Il tourne dans son propre projet compose, avec des limites de CPU sur chaque conteneur serveur. Il monte de 25 à
  800 utilisateurs virtuels (ou plus) via la passerelle REST.
- Résultats sur un Mac de dev : environ 1000 utilisateurs simultanés avant de casser à 1200. OpenFGA a été le
  premier goulot d'étranglement. `docs/annex/load-testing.md` donne les détails.

| | |
| --- | --- |
| **Avantages** | Scénarios en code simple, seuils de réussite/échec clairs, tableau de bord en direct, une seule image Docker. |
| **Inconvénients** | Il teste le REST, pas le chemin gRPC de l'app (une borne prudente). |
| **Pourquoi ce choix** | Facile à scripter, léger en ressources, et il tourne dans Docker. |
| **Alternatives** | Locust, JMeter, Gatling, vegeta. |

### pytest + grpcurl (tests d'API)

Une suite de tests boîte noire en Python (`tests/`, 218 tests) qui tourne contre la stack en marche.
- La plupart des tests utilisent le REST. Les tests d'auth appellent gRPC via `grpcurl`. Les fixtures écrivent utilisateurs et sessions
  directement dans Postgres.

| | |
| --- | --- |
| **Avantages** | Teste ce que voit un vrai client, JSON de la passerelle compris. Rapide à écrire. |
| **Inconvénients** | Demande toute la stack en marche. Écrire directement en base lie les tests au schéma. |
| **Pourquoi ce choix** | Python est rapide pour écrire des tests, et `grpcurl` évite de générer des stubs Python. |
| **Alternatives** | Tests d'intégration en Go (il y en a), Postman/Newman, Bruno. |

### Seed (Go)

`backend/cmd/seed` remplit la base avec un monde de démonstration (122 comptes) ou avec des utilisateurs de test de charge.
Il est intégré à l'image du backend.

| | |
| --- | --- |
| **Avantages** | Même langage et mêmes requêtes que le backend, donc il reste correct quand le schéma change. Sa doc (`docs/annex/init_script_doc.md`) est générée, et un test échoue si elles divergent. |
| **Inconvénients** | Les gros seeds sont lents pendant que le backend tourne (l'outbox doit rattraper son retard). |
| **Pourquoi ce choix** | Réutilise les requêtes sqlc au lieu de dupliquer le schéma dans un script. |
| **Alternatives** | Fichiers SQL de fixtures, un script Python. |
