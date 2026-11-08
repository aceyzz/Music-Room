# Music Room

Application mobile collaborative pour écouter de la musique à plusieurs. Elle
implémente les trois services du sujet :

- **Music Track Vote** : une file d'attente live pour un événement ; chacun
  propose des morceaux et vote, le plus voté passe en premier.
- **Music Control Delegation** : l'hôte confie le contrôle de la lecture à des
  amis, sur l'appareil qui joue le son.
- **Music Playlist Editor** : des playlists éditées à plusieurs, en temps réel.

## Installation

Prérequis : Docker et `make`. Tout le reste est construit dans Docker.

### PC de l'école (sans `/dev/kvm`)

> **7 Go libres minimum** pour Docker · ~10 min la première fois

```bash
make
make seed
```

### PC avec `/dev/kvm`

> **25 Go libres minimum** pour Docker · ~20 min la première fois

```bash
make
make seed
make android
```

`make clean` arrête tout, `make fclean` efface tout (base de données comprise),
`make help` liste les commandes.

## Accès

| Quoi | Où |
| --- | --- |
| App (Linux, taille téléphone, dans le navigateur) | http://localhost:6080 et http://localhost:6081 |
| App Android (avec `/dev/kvm`) | http://localhost:6082 |
| **Documentation de l'API (Swagger)** | **http://localhost:8081/docs/** |
| API REST/JSON | http://localhost:8081 |
| API gRPC (avec réflexion) | `localhost:50051` |

Le Swagger est généré à partir des commentaires des `.proto`
([`proto/music_room/v1/`](proto/music_room/v1/)) : chaque route y a son
résumé, ses champs et ses erreurs. Pour l'essayer, se connecter avec
`POST /v1/auth/login`, puis cliquer sur **Authorize** et coller
`Bearer <session_token>`.

**Compte de démo** : `alex@musicroom.test` / `musicroom42`. Tous les comptes
ont ce mot de passe ; la liste est dans
[docs/annex/init_script_doc.md](docs/annex/init_script_doc.md).

## Stack

| Composant | Technologie |
| --- | --- |
| App mobile | Flutter |
| Back-end | Go, gRPC + passerelle REST/JSON (grpc-gateway) |
| Base de données | PostgreSQL (requêtes générées par sqlc) |
| Autorisations | OpenFGA |
| Images | service en Rust |
| Connexion sociale | Google, 42 |

## Tests

```bash
make docker-api-test      # suite Python de l'API
make docker-backend-test  # tests unitaires Go
make docker-app-test      # tests de l'app Flutter (unitaires et widgets)
make docker-app-test-live # tests de l'app contre le backend lancé
make loadtest             # test de charge (docs/annex/load-testing.md)
```

Tout tourne dans des conteneurs : seul Docker est nécessaire.

## Documentation

- [docs/design_walkthrough.md](docs/design_walkthrough.md) : résumé de l'architecture du projet
- [docs/tech-choices.md](docs/tech_choices.md) : les principaux choix techniques effectués et les raisons
- [docs/who-did-what.md](docs/who-did-what.md) : qui a fait quoi sur le projet
- [docs/annex/data-model.md](docs/annex/data-model.md) : le schéma de la base et ses choix
- [docs/annex/permissions.md](docs/annex/permissions.md) : les règles de permission
- [docs/annex/load-testing.md](docs/annex/load-testing.md) : la montée en charge
- [docs/annex/security.md](docs/annex/security.md) : étude de sécurité
