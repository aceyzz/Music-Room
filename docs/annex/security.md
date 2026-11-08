# Sécurité

Bilan de sécurité de Music Room : ce qui est en place, ce qui ne l'est pas, et pourquoi.
Chaque point renvoie au code qui l'implémente.

## Ce que demande le sujet (V.6)

| Exigence | Où c'est traité |
| --- | --- |
| Un utilisateur n'accède qu'à ses données | [Accès aux données des autres](#accès-aux-données-des-autres-idor) |
| Prévoir le brute force de l'API | [Force brute](#brute-force) |
| Prévoir le vol de session | [Sessions](#sessions-theft) |
| Identifier les autres risques et leurs protections | [Risques connus](#risques-connus-et-acceptés) |
| Journaliser chaque action avec plateforme, appareil, version | [Journalisation](#journalisation) |

## Sessions theft

- Le jeton de session est tiré de `crypto/rand` ([`security/token.go:17`](../backend/internal/security/token.go)). En base, on ne garde que son empreinte SHA-256 ([`token.go:30`](../backend/internal/security/token.go)) : un dump de la table ne permet pas de se connecter.
- Chaque requête vérifie que la session n'est ni révoquée, ni expirée, ni inactive ([`authn/authenticator.go:102-112`](../backend/internal/auth/authn/authenticator.go)). Durée de vie : 30 jours ; inactivité maximale : 7 jours ([`cmd/main.go:142`](../backend/cmd/main.go), [`main.go:194`](../backend/cmd/main.go)).
- Le logout révoque la session. Un reset de mot de passe révoque **toutes** les sessions du compte, dans la même transaction que le changement de mot de passe ([`user/repository.go:560`](../backend/internal/user/repository.go)).
- Côté app, le jeton est rangé dans le stockage sécurisé du système (Keychain, Keystore), pas dans des préférences en clair ([`secure_token_storage.dart`](../frontend/app/lib/core/storage/secure_token_storage.dart)).

Limite : pas de TLS (voir [Risques connus](#risques-connus-et-acceptés)).

## Brute force

| Cible | Limite | Source |
| --- | --- | --- |
| Mot de passe d'un compte | 5 échecs par email sur 15 min, puis refus | [`login/service.go:21`](../backend/internal/auth/login/service.go) |
| Même mot de passe sur beaucoup de comptes | 20 échecs par IP sur 15 min | [`login/service.go:27`](../backend/internal/auth/login/service.go) |
| Toute l'API, gRPC et REST | 100 requêtes/s par IP (rafale de 200), configurable | [`cmd/main.go:201`](../backend/cmd/main.go) |
| Code à 6 chiffres (vérification email, reset) | 5 essais par code, réservés en SQL avant comparaison | [`onetimecode/service.go:19`](../backend/internal/auth/onetimecode/service.go) |
| Envoi de mails | 1 code par minute, 5 par heure, par compte | [`onetimecode/service.go:22-24`](../backend/internal/auth/onetimecode/service.go) |
| Routes sociales (amis, blocage, recherche) | budget par utilisateur | [`interceptor/throttle.go:26-31`](../backend/internal/interceptor/throttle.go) |

Les mots de passe sont hachés en Argon2id, 64 Mo de mémoire ([`security/password.go:22-24`](../backend/internal/security/password.go)), avec 8 caractères minimum ([`register/service.go:19`](../backend/internal/auth/register/service.go)).

Une tentative bloquée n'est pas comptée : un attaquant qui insiste ne prolonge pas le blocage de la victime.

## Énumération des comptes

- **Login** : email inconnu, mauvais mot de passe, compte sans mot de passe ou suspendu renvoient tous `invalid credentials` ([`login/service.go:14`](../backend/internal/auth/login/service.go)).
- **Reset de mot de passe** : la demande répond `{}` que l'email existe ou non ; une erreur interne est journalisée mais pas renvoyée.
- **Inscription** : répond `email already taken` ([`services/auth_service.go:70-72`](../backend/internal/services/auth_service.go)). Risque accepté, voir plus bas.

## Accès aux données des autres (IDOR)

- L'API n'expose que des identifiants publics UUID aléatoires, jamais les identifiants internes ([`db/schema/00017_public_ids.sql`](../backend/db/schema/00017_public_ids.sql)).
- Chaque route passe par l'intercepteur, qui vérifie la permission dans OpenFGA avant le handler ([`docs/authz-enforcement.md`](authz-enforcement.md)).
- Une route absente de la table des politiques est **refusée** (fail closed) ([`interceptor/interceptor.go:175`](../backend/internal/interceptor/interceptor.go)). Seules 6 routes d'authentification sont publiques ([`interceptor/policy.go:110-117`](../backend/internal/interceptor/policy.go)).
- Quand dire « interdit » révélerait que l'objet existe, la réponse est `NotFound` ([`interceptor.go:337`](../backend/internal/interceptor/interceptor.go)).

## Injection

Toutes les requêtes de l'API sont générées par sqlc à partir de [`db/query/`](../backend/db/query) : elles sont paramétrées, aucune valeur utilisateur n'est concaténée dans du SQL. Le seul SQL construit à la main est dans le seed ([`cmd/seed/write.go:84`](../backend/cmd/seed/write.go), [`reset.go:39`](../backend/cmd/seed/reset.go)), un outil lancé en local qui ne reçoit aucune entrée utilisateur.

## Upload d'images

- 5 Mio maximum ([`media/client.go:29`](../backend/internal/media/client.go)) ; PNG, JPEG ou WebP uniquement ([`user/access.go:85`](../backend/internal/user/access.go), [`playlist/access.go:42`](../backend/internal/playlist/access.go)).
- L'image-service décode le fichier puis le **ré-encode en PNG** (`load_from_memory`, puis `write_to` dans [`image-service/src/main.rs`](../image-service/src/main.rs)) : un fichier qui n'est pas une vraie image est rejeté, et ce qui est stocké est une image neuve.
- Les noms de fichiers viennent de `crypto/rand` ([`media/store.go:49`](../backend/internal/media/store.go)), et `/media/` ne liste pas le contenu des dossiers ([`media/files.go`](../backend/internal/media/files.go)).

## Secrets et exposition réseau

- `.env` est ignoré par git ([`.gitignore`](../.gitignore)) ; l'historique a été vérifié, aucun secret n'y a été commité.
- Les mots de passe des deux bases sont dans `.env`, distincts, et **obligatoires** : sans eux, `docker compose` refuse de démarrer ([`docker-compose.yaml`](../docker-compose.yaml)). Aucune valeur par défaut dans le code.
- Les secrets OAuth et SMTP restent côté backend ; l'app ne reçoit que les identifiants publics OAuth.
- Postgres, Redis, OpenFGA, l'image-service et les phones n'écoutent que sur `127.0.0.1`. Seul le backend (`50051`, `8081`) est ouvert sur le réseau, pour l'APK sur un vrai téléphone.

## Journalisation

Chaque appel passe par l'intercepteur, qui l'écrit dans `activity_logs`, refus compris : action, utilisateur, ressource visée, code de résultat, et les en-têtes `x-platform`, `x-device-model`, `x-app-version` envoyés par l'app ([`interceptor/activitylog.go:32`](../backend/internal/interceptor/activitylog.go), [`activitylog.go:96`](../backend/internal/interceptor/activitylog.go)). Détails dans [`docs/authz-enforcement.md`](authz-enforcement.md#activity-logging-v6).

Pour les consulter : `make activity-logs`.

## Risques connus et acceptés

| Risque | Pourquoi on l'accepte | Protection praticable |
| --- | --- | --- |
| **Pas de TLS** : gRPC et HTTP en clair ([`cmd/main.go:209`](../backend/cmd/main.go), [`main.go:336`](../backend/cmd/main.go)), le jeton de session circule lisible | projet local, sans nom de domaine ni certificat | un reverse proxy TLS devant le backend, ou des certificats gRPC |
| **Inscription** : `email already taken` révèle qu'un compte existe | le corriger vraiment demande de ne créer le compte qu'après validation de l'email, sinon la fuite se déplace à la connexion qui suit ; connaître un email ne donne accès à rien | refonte du parcours d'inscription, côté backend et app |
| **Cache OpenFGA** : une permission retirée peut rester valable 1 à 2 s ([`docker-compose.yaml`](../docker-compose.yaml), service `openfga`) | sans cache, OpenFGA saturait le premier en test de charge ([`docs/load-testing.md`](load-testing.md)) | `FGA_CHECK_CACHE=false` |
| **Redis** sans mot de passe | n'écoute que sur `127.0.0.1` et le réseau interne Docker | `requirepass` |

## Vérifier soi-même

```bash
make docker-api-test                               # suite d'API, permissions et authentification comprises
curl -s -o /dev/null -w "%{http_code}\n" localhost:8081/media/   # 404 : pas de liste de dossier
make activity-logs                                 # dernières actions journalisées
```
