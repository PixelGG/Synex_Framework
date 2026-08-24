<p align="center">
  <img src="../../../.github/assets/branding/synex-mark.svg" width="96" height="96" alt="Symbole Synex">
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
  <img alt="Version : 0.1.0" src="https://img.shields.io/badge/version-0.1.0-4b94ff?style=flat-square&amp;labelColor=111827">
  <img alt="Maturité : experimental" src="https://img.shields.io/badge/maturity-experimental-8b73ff?style=flat-square&amp;labelColor=111827">
  <a href="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml?query=branch%3Amain"><img alt="Framework CI" src="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml/badge.svg?branch=main"></a>
  <a href="../../../LICENSE"><img alt="Licence : AGPL-3.0-only" src="https://img.shields.io/badge/license-AGPL--3.0--only-45c9a5?style=flat-square&amp;labelColor=111827"></a>
</p>

<p align="center">
  <img src="../../../.github/assets/readme/runtime-flow.svg" width="1200" alt="Flux modulaire du runtime Synex">
</p>

> [!CAUTION]
> **Version source expérimentale.** Synex `0.1.0` contient des ressources de fondation exécutables, des contrats générés, des migrations, des tests et des outils. Tous les contrats publics restent `experimental` ; il n'existe pas encore de version stable, d'installateur packagé ni de garantie de support en production.

## État de validation actuel

Le build d'acceptation du 24/08/2026 a terminé ses étapes côté serveur et avec un vrai client. L'état actuel ajoute deux corrections de durcissement ultérieures, vérifiées par les tests du dépôt et de la base de données réelle ; la séquence manuelle FXServer/client complète n'a pas encore été répétée sur cette révision combinée. Il s'agit d'une preuve dans ces limites, pas d'une revendication de stabilité ou de préparation à la production.

- **PASS — Vérifications du dépôt.** Génération, validation, suites headless, analyse statique de sécurité et audit des dépendances.
- **PASS — Base de données réelle.** Base MariaDB 11.8 et les 26 migrations du Core.
- **PASS — Build d'acceptation E2E.** `READY` côté serveur, API liées à l'appelant, exécution persistée des Sagas, récupération après redémarrage, connexion/déconnexion/reconnexion avec un vrai client et redémarrage préparé avec travail de base de données en attente.
- **SUIVI VÉRIFIÉ — Durcissement actuel.** Le traitement terminal des nouvelles tentatives de redémarrage ainsi que la vérification exacte de l'expression générée et de l'utilisabilité de l'index forcé de la migration 026 ont passé les régressions headless et MariaDB réelles ; la séquence manuelle FXServer/client complète doit être répétée avant l'acceptation d'une version.
- **NON TESTÉ — Relève à deux instances.** Le redémarrage du demandeur pendant `kick_old` nécessite encore une validation multi-instance dédiée.

[Couverture exacte et séquence client restante](../../testing.md)

## Fondation implémentée

| Domaine | Module | Responsabilité réellement présente |
| --- | --- | --- |
| Kernel | [`synex_core`](../../../core/synex_core/) | Cycle de vie boot/session/personnage, contrats, RPC, événements, hooks, services, capabilities, RBAC/accès persistant, état, fiabilité, audit, métriques et santé |
| Groupes | [`synex_groups`](../../../resources/synex_groups/) | Groupes, grades, règles de capability, sélection primaire et appartenances versionnées |
| Comptes | [`synex_accounts`](../../../resources/synex_accounts/) | Devises, comptes en partie double, réservations, rôles d'accès, annulations et modèles d'intégrité |
| Entités | [`synex_entities`](../../../resources/synex_entities/) | Identité d'entité authoritative côté serveur, résolution persistante et routing buckets |
| Opérations | [`synex_control`](../../../resources/synex_control/) | NUI en jeu en lecture seule avec vues Core/domaines bornées, recherche d'audit exacte et état fermé transparent |
| Compatibilité | [`synex_bridge`](../../../libraries/synex_bridge/) | Adaptateurs QB/QBX/ESX optionnels liés au consommateur, avec callbacks bornés, transferts cash/bank et import contrôlé |
| Développement | [`packages`](../../../packages/) / [`tools`](../../../tools/) | SDK Lua/TypeScript générés, CLI, analyseurs, certification et tests |

Toutes les fondations implémentées restent expérimentales. Le chemin de compatibilité est en plus déprécié pour les nouveaux projets.

Les adaptateurs de compatibilité n'exposent pas d'objets joueur legacy mutables. Les changements monétaires passent uniquement par des transferts Synex équilibrés via des comptes de contrepartie configurés ; les comptes absents ou ambigus échouent de manière fermée.

Synex lie chaque façade API à la ressource appelante réelle et à son epoch de démarrage. Les contrats JSON définissent version, schéma, capability et direction réseau. Chaque migration et table a un seul propriétaire de domaine. Les entrées client et NUI restent non fiables.

### Limites uniquement réservées

`synex_character`, `synex_identity`, `synex_inventory`, `synex_banking`, `synex_phone`, `synex_radio`, `synex_jobs`, `synex_shops`, `synex_vehicles`, `synex_garages` et `synex_ui` ne contiennent actuellement que des scaffolds et ne sont **pas des fonctionnalités exécutables**. Le cycle de vie personnage/session existant se trouve dans `synex_core`.

## Démarrage

Il faut un FXServer actuel, MariaDB 11.8 ou MySQL 8.4 via `oxmysql >= 2.14.1` (et `< 3.0.0` lorsque `synex_entities` est activé), un `synex_instance_id` stable en production stricte et OneSync `on` pour `synex_entities`. Node.js sert aux outils et aux tests du dépôt, pas au runtime Lua.

```bash
git clone https://github.com/PixelGG/Synex_Framework.git
cd Synex_Framework
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

## Communauté

Les discussions de développement, les retours d'implémentation et les mises à jour du framework sont disponibles dans la communauté officielle Synex.

<p align="center">
  <a href="https://discord.gg/heJU5t2Hfa">
    <img src="../../../.github/assets/readme/discord-community.svg" width="720" alt="Rejoindre le Discord officiel de Synex">
  </a>
</p>

## Licence

Copyright &copy; 2026 PixelGG. Synex est distribué exclusivement sous la [GNU Affero General Public License v3.0](../../../LICENSE).

---

<p align="center"><sub>Synex Framework &middot; Contrats explicites. État attribué. Limites honnêtes.</sub></p>
