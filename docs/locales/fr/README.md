<p align="center">
  <img src="../../../.github/assets/branding/synex-mark.svg" width="96" height="96" alt="Symbole Synex">
</p>

<h1 align="center">Synex</h1>

<p align="center">
  <strong>Un Core FiveM contract-first fondé sur des responsabilités explicites et des limites fail-closed.</strong>
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
> **Candidat Production-Beta du Core — IN PROGRESS / NO-GO.** Synex `0.1.0` reste une version source expérimentale. Seul `synex_core` est évalué pour le premier profil Production-Beta, et le candidat exact actuel n'a pas encore franchi toutes les étapes obligatoires. Les contrats publics restent `experimental` ; il n'existe aucune version stable ni garantie de support en production pour l'ensemble du framework.

## État de validation actuel

Le candidat exact précédent `888a7326` a franchi le gate automatisé et les principales étapes d'acceptation côté serveur : démarrage neuf du Core avec 26 migrations, sonde externe des API publiques, redémarrages préparés et non préparés du Core, crash complet du processus avec reprise, panne de base de données en mode fail-closed avec reprise par redémarrage complet de FXServer, sauvegarde/restauration et mise à niveau réelle de la baseline `cd4b3cd5` de 25 à 26 migrations. Le soak minimal prévu de 120 minutes a toutefois échoué lors de la première exécution horaire du worker de rétention de l'outbox, avant d'atteindre la durée minimale, car une configuration de rétention valide décodée par Cfx a été rejetée.

- **PREUVES DU CANDIDAT PRÉCÉDENT.** Les étapes serveur, de reprise, de sauvegarde/restauration et de mise à niveau citées ont réussi pour `888a7326`, mais l'échec ultérieur du soak interdit de les considérer comme un PASS complet du candidat.
- **REPRISE DE PANNE BORNÉE.** Dans la condition testée de callback oxmysql perdu, l'admission des joueurs reste fermée. Aucune reprise automatique n'est revendiquée : après restauration du service de base de données, les opérateurs doivent redémarrer l'intégralité du processus FXServer avant de rouvrir l'admission.
- **ARBRE RUNTIME ACTUEL / IN PROGRESS.** Le correctif introduit par `e0cbf45` accepte les conteneurs objet JSON Cfx de confiance dans le chemin de rétention de l'outbox ; les contrôles du dépôt et headless ont réussi. La révision propre sélectionnée après la documentation doit encore passer le gate serveur exact, un nouveau soak de 120 minutes et le test du cycle de vie client. Tant que ces trois preuves n'ont pas réussi, la décision reste NO-GO et il ne s'agit pas d'une bêta stable en production.
- **NON CERTIFIÉ.** MySQL et le fonctionnement multi-instance, y compris `kick_old`, sont hors du premier profil candidat.
- **HORS PÉRIMÈTRE.** Chaque ressource, bibliothèque, bridge et exemple en aval de `synex_core` est un snapshot de rework expérimental ou un scaffold, exclu de la certification du Core.

[Gate de release](../../release-readiness.md) &middot; [Couverture des tests](../../testing.md) &middot; [Limites connues](../../known-limitations.md)

### Premier profil cible d'acceptation

| Limite | Valeur candidate |
| --- | --- |
| Produit | `synex_core` uniquement |
| Hôte | Windows |
| Runtime | FXServer build `35245` |
| Adaptateur de base de données | `oxmysql 2.14.1` |
| Base de données | MariaDB `11.8.8`, heure de session UTC |
| Topologie | une instance Core active |
| Politique de production | `synex_environment "production"`, `synex_strict "1"`, `synex_duplicate_policy "deny_new"` |

Ces valeurs définissent le candidat ; elles ne constituent pas encore un PASS.

## Périmètre de la bêta Core

| Domaine | Chemin | Rôle actuel |
| --- | --- | --- |
| Candidat runtime | [`synex_core`](../../../core/synex_core/) | Boot, connexions, cycles session/personnage, contrats, RPC, événements, hooks, services, capabilities, politique d'accès persistante, état, fiabilité, audit, métriques, santé et migrations propres |
| Pipeline de contrats | [`packages/contracts`](../../../packages/contracts/) | Entrées canoniques et artefacts runtime/référence générés de façon déterministe pour le développement du Core |
| SDK et outils | [`packages`](../../../packages/) / [`tools`](../../../tools/) | Clients/types générés, validation, migration, sécurité, certification et tests ; ce ne sont pas des fonctions serveur certifiées séparément |

Seul `core/synex_core` peut devenir Production-Beta-ready dans le cycle actuel. L'API publique du Core reste expérimentale même si le gate bêta réussit.

### Limite de rework en aval

`synex_groups`, `synex_accounts`, `synex_entities`, `synex_control`, tous les répertoires ultérieurs ou indépendants sous `resources/`, toutes les bibliothèques et tous les bridges sous `libraries/` (dont `synex_bridge`), ainsi que les exemples exécutables sont **des snapshots de rework expérimentaux ou des scaffolds**. Ils sont entièrement exclus de la bêta Core et ne doivent être ni démarrés, ni regroupés, ni présentés comme des composants certifiés. Les comportements en aval dépendant de OneSync sont également hors de ce profil Core-only.

Cela inclut aussi `synex_character`, `synex_identity`, `synex_inventory`, `synex_banking`, `synex_phone`, `synex_radio`, `synex_jobs`, `synex_shops`, `synex_vehicles`, `synex_garages` et `synex_ui`. La présence d'un répertoire ne prouve pas l'existence d'une fonctionnalité terminée. Le cycle personnage/session existant appartient à `synex_core`.

## Démarrage

Le premier profil candidat exige Windows, FXServer build `35245`, `oxmysql 2.14.1`, MariaDB `11.8.8`, un `synex_instance_id` stable et unique, le mode production strict et `deny_new`. Node.js `>=22.12.0` avec npm `>=10.0.0` sert aux outils et aux tests du dépôt, pas au runtime Lua.

```bash
git clone https://github.com/PixelGG/Synex_Framework.git
cd Synex_Framework
npm ci
npm run check
npm test
npm run security
npm run certify
```

Ces commandes sont des gates de développement et ne suffisent pas à prouver une Production-Beta. Ce dépôt reste un monorepo de développement, pas un paquet serveur prêt à déposer. Pour le premier candidat, ne déployez que `oxmysql` et `synex_core`. Consultez le [guide de démarrage](../../getting-started.md), l'[exemple de configuration Core](../../../examples/server.cfg.example) et le [gate de release](../../release-readiness.md).

## Documentation

L'anglais reste la source technique canonique.

- [Index de documentation](../../README.md)
- [Gate Production-Beta du Core](../../release-readiness.md)
- [Limites connues](../../known-limitations.md)
- [Sauvegarde et restauration](../../backup-and-restore.md)
- [Architecture](../../architecture/README.md)
- [API publique](../../api/README.md)
- [Sécurité](../../security/README.md)
- [Politique de sécurité](../../../SECURITY.md)
- [Opérations](../../operations.md)
- [Tests et CI](../../testing.md)

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
