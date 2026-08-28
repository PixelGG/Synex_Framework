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
  <img alt="Maturité du Core : Production Beta" src="https://img.shields.io/badge/core-Production--Beta-8b73ff?style=flat-square&amp;labelColor=111827">
  <a href="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml?query=branch%3Amain"><img alt="Framework CI" src="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml/badge.svg?branch=main"></a>
  <a href="../../../LICENSE"><img alt="Licence : AGPL-3.0-only" src="https://img.shields.io/badge/license-AGPL--3.0--only-45c9a5?style=flat-square&amp;labelColor=111827"></a>
</p>

<p align="center">
  <img src="../../../.github/assets/readme/runtime-flow.svg" width="1200" alt="Flux modulaire du runtime Synex">
</p>

> [!IMPORTANT]
> **Synex Core — PRODUCTION BETA.** Le candidat `synex_core` exact a réussi le premier profil Production-Beta limité au Core. Synex `0.1.0` reste une version source expérimentale dont les contrats publics sont marqués `experimental`. Il ne s'agit ni d'une version Stable/1.0, ni d'une déclaration de maturité de l'ensemble du framework, ni d'une garantie générale de support en production.

## État de validation actuel

`synex_core` a franchi la ligne d'acceptation Production-Beta gelée le **25-08-2026** pour le profil exact ci-dessous. La décision s'applique uniquement au commit Core `7ad4b72ee9bcd0a2a0481cfacfe5f807eb1b3ec5` et à l'arbre Core `9f0960f1e27fe43195ae4602cb2ef447cbc0509b`. Les ajouts actuels du Core pour la persistance de domaine et la suppression coordonnée constituent un candidat ultérieur et n'héritent pas de cette acceptation.

| Étape de clôture | État actuel |
| --- | --- |
| Test final de panne et de reprise de la base de données | PASS |
| Exécution automatisée complète de clôture | PASS — `npm run check` ; 416 réussis, 0 échec, 19 skips live-DB attendus ; sécurité : 0 finding ; audit : 0 vulnérabilité |
| Synchronisation de toute la documentation du dépôt | PASS |
| Smoke test client : connexion, déconnexion, reconnexion | PASS — pipeline de connexion ordonné en neuf étapes, déconnexion propre, reconnexion et nettoyage final |
| Revue finale du diff et des secrets ; commit et publication sur `main` | PASS |

- **PRODUCTION-BETA ACCEPTÉE.** La reprise après panne de base de données, l'exécution automatisée de clôture, la synchronisation de la documentation, le smoke test client, la revue finale et les gates de publication ont réussi pour le profil exact limité au Core.
- **CLIENT RÉEL VÉRIFIÉ.** La connexion a franchi les neuf étapes dans l'ordre prévu, suivie d'une déconnexion propre et d'une reconnexion réussie. Doctor a renvoyé `PASS`, les 26 migrations ont été appliquées et le nettoyage final a laissé 3 sessions fermées, 0 session ouverte et 0 lease actif de session ou d'admission.
- **MATURITÉ LIMITÉE.** Cette acceptation ne transforme pas Synex en Stable/1.0, ne certifie pas l'ensemble du framework et ne modifie pas le statut `experimental` des contrats publics du Core.
- **NON CERTIFIÉ.** MySQL et le fonctionnement multi-instance, y compris `kick_old`, sont hors du profil Production-Beta accepté.
- **HORS PÉRIMÈTRE.** `synex_groups` et `synex_accounts` sont des engines Experimental Alpha indépendantes. `synex_entities` est une Entity Authority Engine server-only en Development / Experimental Alpha ; son implémentation est présente dans le dépôt, mais les validations réelles MariaDB, FXServer/OneSync, redémarrage/récupération, cluster, client/Control et du candidat exact restent ouvertes. `synex_world` est une ressource World Semantics & Spatial Authority en Development / Experimental Alpha ; ses validations réelles MariaDB, FXServer/OneSync, client natif et redémarrage restent ouvertes. Les projections de domaine en lecture seule dans `synex_control` sont expérimentales. `synex_bridge` est implémenté comme Compatibility Platform Experimental Alpha fail-closed, mais n'a pas encore d'acceptation réelle. `synex_ui` est implémenté comme fondation UI en Experimental Alpha ; sa validation réelle FiveM/CEF reste ouverte. Les autres ressources, bibliothèques et exemples restent des snapshots de rework ou des scaffolds. Aucun ne fait partie de la certification Core gelée.

Le `synex_control` optionnel et en lecture seule est implémenté comme surface d'opérations Development / Experimental Alpha avec des contrôles automatisés des providers, du transport, du sanitizer et de la NUI. Le cycle de vie réel des providers sur FXServer et l'acceptation CEF/client restent ouverts ; ces contrôles automatisés ne constituent pas une promotion de maturité.

<details>
<summary>Hardening post-bêta — explicitement hors de ce gate d'acceptation</summary>

- soak de 125 minutes
- runner permanent de collecte de preuves
- répétition historique de mise à niveau
- répétition étendue de sauvegarde et restauration
- tests ABI non critiques supplémentaires

Ces contrôles appartiennent au travail nécessaire pour sortir ultérieurement de la bêta. Ils n'élargissent pas la ligne de clôture Production-Beta gelée.

</details>

[Gate de release](../../release-readiness.md) &middot; [Couverture des tests](../../testing.md) &middot; [Limites connues](../../known-limitations.md)

### Profil Production-Beta accepté

| Limite | Valeur acceptée |
| --- | --- |
| Produit | `synex_core` uniquement |
| Hôte | Windows |
| Runtime | FXServer build `35245` |
| Adaptateur de base de données | `oxmysql 2.14.1` |
| Base de données | MariaDB `11.8.8`, heure de session UTC |
| Topologie | une instance Core active |
| Politique de production | `synex_environment "production"`, `synex_strict "1"`, `synex_duplicate_policy "deny_new"` |

La décision Production-Beta n'est valable que dans ces limites. Toute autre plateforme, version de dépendance, topologie ou politique nécessite ses propres preuves d'acceptation.

## Périmètre de la bêta Core

| Domaine | Chemin | Rôle actuel |
| --- | --- | --- |
| Runtime Core accepté | [`synex_core`](../../../core/synex_core/) | Boot, connexions, cycles session/personnage, contrats, RPC, événements, hooks, services, capabilities, politique d'accès persistante, état, fiabilité, audit, métriques, santé et migrations propres |
| Pipeline de contrats | [`packages/contracts`](../../../packages/contracts/) | Entrées canoniques et artefacts runtime/référence générés de façon déterministe pour le développement du Core |
| SDK et outils | [`packages`](../../../packages/) / [`tools`](../../../tools/) | Clients/types générés, validation, migration, sécurité, certification et tests ; ce ne sont pas des fonctions serveur certifiées séparément |

Seul `core/synex_core` est accepté comme Production-Beta-ready pour le profil exact ci-dessus. L'API publique du Core reste expérimentale.

### Limite de maturité en aval

`synex_groups` est l'Organizations Engine en Experimental Alpha. Le catalogue actuel contient 71 contrats Groups et 31 migrations : 70 contrats sont locaux au serveur et seul `synex.groups.self.snapshot` est une projection client limitée et liée à la session. Les preuves live antérieures précèdent la migration `032` ; les contrôles client, candidat et maturité actuels restent ouverts. `synex_accounts` est désormais une Financial Engine Experimental Alpha exclusivement serveur, avec 59 contrats locaux et 18 migrations. Le 28-08-2026, l'arbre de travail actuel a réussi le périmètre de base de données isolé sur MariaDB 11.8.8 avec 104/104 tests ; FXServer, redémarrage/récupération, mise à niveau restaurée, candidat exact et décision de maturité restent ouverts. Accounts n'a aucune interface client ou NUI ; le gameplay et l'UI appartiendront plus tard à `synex_banking`. `synex_entities` est une Entity Authority Engine server-only en Development / Experimental Alpha, avec 33 définitions de contrat versionnées sous 32 noms et quatre migrations propres. L'implémentation et les régressions du dépôt sont présentes ; les validations réelles MariaDB, FXServer/OneSync, redémarrage/récupération, cluster, client/Control et du candidat exact restent ouvertes. `synex_world` fournit des bundles déclaratifs, un graphe et une géométrie compilés, le contexte spatial, les portes, portails, états, instances et un cache client en lecture seule, mais reste en Development / Experimental Alpha jusqu'aux validations réelles MariaDB, FXServer/OneSync, client natif et redémarrage. Les projections de domaine en lecture seule dans `synex_control` sont implémentées, mais expérimentales. `synex_bridge` possède des providers QB/QBX/ESX séparés, mais reste Experimental Alpha sans acceptation FXServer/client exacte. Les ressources ultérieures, autres bibliothèques et exemples exécutables restent des snapshots de rework ou des scaffolds. Aucun ne fait partie de la bêta Core.

`synex_ui` est implémenté comme fondation UI en Experimental Alpha, avec un package React de build et une runtime client FiveM distincte. Les contrôles automatisés de types, unités/composants, navigateur, build, transport et état fermé ne remplacent pas les validations réelles FiveM/CEF, safe-zone, manette, restauration du focus, lisibilité sur le gameplay et performances, qui restent ouvertes. L'UI n'hérite pas de la certification Core.

Cela inclut aussi les noms de gameplay réservés `synex_character`, `synex_identity`, `synex_inventory`, `synex_banking`, `synex_phone`, `synex_radio`, `synex_jobs`, `synex_shops`, `synex_vehicles` et `synex_garages`. La présence d'un répertoire ne prouve pas l'existence d'une fonctionnalité terminée. Le cycle personnage/session existant appartient à `synex_core`.

## Démarrage

Le profil Production-Beta accepté exige Windows, FXServer build `35245`, `oxmysql 2.14.1`, MariaDB `11.8.8`, un `synex_instance_id` stable et unique, le mode production strict et `deny_new`. Node.js `>=22.12.0` avec npm `>=10.0.0` sert aux outils et aux tests du dépôt, pas au runtime Lua.

```bash
git clone https://github.com/PixelGG/Synex_Framework.git
cd Synex_Framework
npm ci
npm run check
npm test
npm run security
npm run certify
```

Ces commandes sont des gates de développement et ne suffisent pas à prouver une Production-Beta. Ce dépôt reste un monorepo de développement, pas un paquet serveur prêt à déposer. Pour le profil accepté, ne déployez que `oxmysql` et `synex_core`. Consultez le [guide de démarrage](../../getting-started.md), l'[exemple de configuration Core](../../../examples/server.cfg.example) et le [gate de release](../../release-readiness.md).

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
- [Fondation UI](../../ui/README.md)
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
