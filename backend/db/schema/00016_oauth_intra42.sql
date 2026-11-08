-- Ajoute intra42 a oauth_provider.
--
-- Numerotee 00016 et non 00015 : elle partageait ce numero avec
-- 00015_openfga_outbox.sql, arrivee par une autre branche. goose panique sur un
-- numero en double ("duplicate version 15 detected") et le backend ne demarrait
-- plus du tout. C'est celle-ci qui bouge parce que c'est l'autre qui a ete
-- appliquee : la version 15 enregistree en base est celle de l'outbox, et cette
-- migration-ci n'avait jamais tourne -- l'enum n'avait donc pas intra42, et une
-- connexion 42 echouait sur une valeur d'enum inexistante.
--
-- ALTER TYPE ... ADD VALUE ne tourne pas dans une transaction, d'ou
-- l'annotation ci-dessous. C'est la seule migration du projet qui en a besoin
-- (00003_enums en parle en prose, sans la citer, parce que goose lit aussi
-- les commentaires).
--
-- Pas de Down : PostgreSQL ne sait pas retirer une valeur d'un enum. Il
-- faudrait recreer le type et reecrire toutes les colonnes qui l'utilisent.

-- +goose NO TRANSACTION

-- +goose Up
ALTER TYPE oauth_provider ADD VALUE IF NOT EXISTS 'intra42';

-- +goose Down
SELECT 1;
