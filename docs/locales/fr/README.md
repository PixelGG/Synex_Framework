<p align="center">
  <img src="../../../.github/assets/branding/synex-mark.svg" width="88" height="88" alt="Symbole Synex">
</p>

<h1 align="center">Synex</h1>

<p align="center">
  <strong>Un runtime FiveM contract-first et une fondation pour des ressources aux responsabilités indépendantes.</strong>
</p>

<p align="center">
  <a href="../../../README.md">EN</a>
  &nbsp;&middot;&nbsp;
  <a href="../de/README.md">DE</a>
  &nbsp;&middot;&nbsp;
  <strong>FR</strong>
  &nbsp;&middot;&nbsp;
  <a href="../es/README.md">ES</a>
  &nbsp;&middot;&nbsp;
  <a href="../pt-BR/README.md">PT-BR</a>
</p>

<p align="center">
  <img alt="Cible : FiveM" src="https://img.shields.io/badge/target-FiveM-5ed7ff?style=flat-square&amp;labelColor=111827">
  <img alt="Version : 0.1.0 experimental" src="https://img.shields.io/badge/release-0.1.0%20experimental-8b73ff?style=flat-square&amp;labelColor=111827">
</p>

<p align="center">
  <img src="../../../.github/assets/readme/hero.webp" width="1200" alt="Illustration abstraite du réseau modulaire Synex">
</p>

> [!CAUTION]
> **Version source expérimentale.** Synex `0.1.0` contient des ressources de fondation exécutables, des contrats générés, des migrations, des tests et des outils. Tous les contrats publics restent `experimental` ; il n'existe pas encore de version stable, d'installateur packagé ni de garantie de support en production.

## Fondation implémentée

| Domaine | Module | Responsabilité réellement présente | Statut |
| --- | --- | --- | --- |
| Kernel | [`synex_core`](../../../core/synex_core/) | Cycle de vie boot/session/personnage, contrats, RPC, événements, hooks, services, capabilities, RBAC/accès persistant, état, fiabilité, audit, métriques et santé | Experimental |
| Groupes | [`synex_groups`](../../../resources/synex_groups/) | Groupes, grades, règles de capability, sélection primaire et appartenances versionnées | Experimental |
| Comptes | [`synex_accounts`](../../../resources/synex_accounts/) | Devises, comptes en partie double, réservations, rôles d'accès, annulations et modèles d'intégrité | Experimental |
| Entités | [`synex_entities`](../../../resources/synex_entities/) | Identité d'entité authoritative côté serveur, résolution persistante et routing buckets | Experimental |
| Opérations | [`synex_control`](../../../resources/synex_control/) | NUI en jeu en lecture seule avec vues Core/domaines bornées, recherche d'audit exacte et état fermé transparent | Experimental |
| Compatibilité | [`synex_bridge`](../../../libraries/synex_bridge/) | Adaptateurs QB/QBX/ESX optionnels liés au consommateur, avec callbacks bornés, transferts cash/bank et import contrôlé | Experimental / transition |
| Développement | [`packages`](../../../packages/) / [`tools`](../../../tools/) | SDK Lua/TypeScript générés, CLI, analyseurs, certification et tests | Experimental |

Les adaptateurs de compatibilité n'exposent pas d'objets joueur legacy mutables. Les changements monétaires passent uniquement par des transferts Synex équilibrés via des comptes de contrepartie configurés ; les comptes absents ou ambigus échouent de manière fermée.

Synex lie chaque façade API à la ressource appelante réelle et à son epoch de démarrage. Les contrats JSON définissent version, schéma, capability et direction réseau. Chaque migration et table a un seul propriétaire de domaine. Les entrées client et NUI restent non fiables.

### Limites uniquement réservées

`synex_character`, `synex_identity`, `synex_inventory`, `synex_banking`, `synex_phone`, `synex_radio`, `synex_jobs`, `synex_shops`, `synex_vehicles`, `synex_garages` et `synex_ui` ne contiennent actuellement que des scaffolds et ne sont **pas des fonctionnalités exécutables**. Le cycle de vie personnage/session existant se trouve dans `synex_core`.

## Démarrage

Il faut un FXServer actuel, MariaDB/MySQL via `oxmysql >= 2.14.1` (et `< 3.0.0` lorsque `synex_entities` est activé), un `synex_instance_id` stable en production stricte et OneSync `on` pour `synex_entities`. Node.js sert aux outils et aux tests du dépôt, pas au runtime Lua.

```bash
npm ci
npm run check
npm test
npm run security
npm run certify
```

Ce dépôt est un monorepo de développement, pas un paquet serveur prêt à déposer. Le [guide de démarrage](../../getting-started.md) décrit placement, configuration, migrations, ordre de démarrage et limites.

## Documentation

L'anglais reste la source technique canonique.

- [Index de documentation](../../README.md)
- [Architecture](../../architecture/README.md)
- [API publique](../../api/README.md)
- [Sécurité](../../security/README.md)
- [Opérations](../../operations.md)
- [Tests et CI](../../testing.md)
- [Compatibilité](../../compatibility/README.md)

---

<p align="center"><sub>Synex Framework &middot; Contrats explicites. État attribué. Limites honnêtes.</sub></p>
