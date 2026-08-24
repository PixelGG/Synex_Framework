<p align="center">
  <img src="../../../.github/assets/branding/synex-mark.svg" width="96" height="96" alt="Synex Markenzeichen">
</p>

<h1 align="center">Synex</h1>

<p align="center">
  <strong>Ein contract-first FiveM-Core mit klarer Verantwortung und fail-closed Grenzen.</strong>
</p>

<p align="center">
  <a href="../../../README.md">EN</a>
  &nbsp;&middot;&nbsp;
  <strong>DE</strong>
  &nbsp;&middot;&nbsp;
  <a href="../fr/README.md">FR</a>
  &nbsp;&middot;&nbsp;
  <a href="../es/README.md">ES</a>
  &nbsp;&middot;&nbsp;
  <a href="../pt-BR/README.md">PT-BR</a>
</p>

<p align="center">
  <img alt="Ziel: FiveM" src="https://img.shields.io/badge/target-FiveM-5ed7ff?style=flat-square&amp;labelColor=111827">
  <img alt="Version: 0.1.0" src="https://img.shields.io/badge/version-0.1.0-4b94ff?style=flat-square&amp;labelColor=111827">
  <img alt="Reifegrad: experimental" src="https://img.shields.io/badge/maturity-experimental-8b73ff?style=flat-square&amp;labelColor=111827">
  <a href="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml?query=branch%3Amain"><img alt="Framework CI" src="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml/badge.svg?branch=main"></a>
  <a href="../../../LICENSE"><img alt="Lizenz: AGPL-3.0-only" src="https://img.shields.io/badge/license-AGPL--3.0--only-45c9a5?style=flat-square&amp;labelColor=111827"></a>
</p>

<p align="center">
  <img src="../../../.github/assets/readme/runtime-flow.svg" width="1200" alt="Modularer Synex-Runtime-Flow">
</p>

> [!CAUTION]
> **Core-Production-Beta-Kandidat — IN PROGRESS / NO-GO.** Synex `0.1.0` ist weiterhin ein experimenteller Source-Release. Nur `synex_core` wird für das erste Production-Beta-Profil abgenommen; der exakte aktuelle Kandidat hat noch nicht alle Pflicht-Gates bestanden. Öffentliche Contracts bleiben `experimental`. Es gibt keinen frameworkweiten Stable- oder Production-Support-Anspruch.

## Aktueller Prüfstand

Entwicklungsdurchläufe haben Repository-Gates, die MariaDB-Kette mit 26 Migrationen, einen isolierten FXServer-Start, öffentliche Core-APIs, Recovery-Pfade sowie Join/Disconnect/Reconnect mit einem echten Client bereits ausgeführt. Diese Nachweise zertifizieren keine andere Revision. Die Entscheidung bleibt NO-GO, bis die vollständige Abnahme für genau einen sauberen, unveränderlichen Kandidaten dokumentiert ist.

- **IN DER ENTWICKLUNG VERIFIZIERT.** Generation, Validierung, Headless-Suites, statische Security-Analyse, Dependency-Audit, Live-MariaDB-Regressionen und frühere FXServer-/Client-Stufen waren erfolgreich.
- **IMPLEMENTIERT; LIVE-RETEST AUSSTEHEND.** Der Runtime-Datenbank-Health-Circuit versetzt den Core nach einem zurückgegebenen Fehler, einer Adapter-Exception oder Ablauf des festen fünfsekündigen Fail-closed-Watchdogs in ein wiederherstellbares `DEGRADED` mit `operational = true` und geschlossener Player-Admission. Er pausiert die gewöhnlichen datenbankgestützten Worker, während der begrenzte Connection-Heartbeat für Cleanup bewusst aktiv bleibt, und verlangt zwei erfolgreiche Probes plus Reconciliation, bevor Datenbankarbeit und Admission fortgesetzt werden. Dafür existieren fokussierte Headless- und Cfx-nahe Coroutine-Tests, aber noch kein Live-PASS des exakten Kandidaten.
- **IN PROGRESS.** Fresh Install, Upgrade, Backup/Restore, Restart-/Crash-Recovery, Datenbankausfall und -wiederherstellung, begrenzter Load-/Soak-Test, Security Review, Doku-Audit und die vollständige Client-Sequenz müssen auf derselben Revision bestehen.
- **NICHT ZERTIFIZIERT.** MySQL und Multi-Instance-Betrieb einschließlich `kick_old` gehören nicht zum ersten Kandidatenprofil.
- **AUSSERHALB DES SCOPES.** Jede Resource, Library, Bridge und jedes Beispiel hinter `synex_core` ist ein experimenteller Rework-Snapshot oder Scaffold und gehört nicht zur Core-Zertifizierung.

[Release-Gate](../../release-readiness.md) &middot; [Testabdeckung](../../testing.md) &middot; [Bekannte Grenzen](../../known-limitations.md)

### Erstes Zielprofil für die Abnahme

| Grenze | Kandidatenwert |
| --- | --- |
| Produkt | ausschließlich `synex_core` |
| Host | Windows |
| Runtime | FXServer-Build `35245` |
| Datenbankadapter | `oxmysql 2.14.1` |
| Datenbank | MariaDB `11.8.8`, Session-Zeit in UTC |
| Topologie | eine aktive Core-Instanz |
| Production-Policy | `synex_environment "production"`, `synex_strict "1"`, `synex_duplicate_policy "deny_new"` |

Diese Werte definieren den Kandidaten und sind noch keine PASS-Aussage.

## Core-Beta-Scope

| Bereich | Pfad | Aktuelle Rolle |
| --- | --- | --- |
| Runtime-Kandidat | [`synex_core`](../../../core/synex_core/) | Boot, Connection-/Session-/Character-Lifecycle, Contracts, RPC, Events, Hooks, Services, Capabilities, persistente Access-Policy, State, Reliability, Audit, Metrics, Health und eigene Migrationen |
| Contract-Pipeline | [`packages/contracts`](../../../packages/contracts/) | Kanonische Inputs und deterministisch generierte Runtime-/Referenzartefakte für die Core-Entwicklung |
| SDKs und Tools | [`packages`](../../../packages/) / [`tools`](../../../tools/) | Generierte Clients/Typen, Validierung, Migration, Security, Certification und Tests; keine separat zertifizierten Server-Features |

Nur `core/synex_core` kann im aktuellen Durchlauf Production-Beta-ready werden. Die öffentliche Core-API bleibt auch nach einem bestandenen Beta-Gate experimentell.

### Downstream-Rework-Grenze

`synex_groups`, `synex_accounts`, `synex_entities`, `synex_control`, alle weiteren Verzeichnisse unter `resources/`, sämtliche Libraries und Bridges unter `libraries/` (einschließlich `synex_bridge`) sowie die ausführbaren Beispiele sind **experimentelle Rework-Snapshots oder Scaffolds**. Sie sind für die Core-Beta nicht unterstützt und dürfen nicht als zertifizierte Komponenten gestartet, gebündelt oder beworben werden. OneSync-abhängiges Downstream-Verhalten liegt ebenfalls außerhalb dieses Core-only-Profils.

Das gilt auch für `synex_character`, `synex_identity`, `synex_inventory`, `synex_banking`, `synex_phone`, `synex_radio`, `synex_jobs`, `synex_shops`, `synex_vehicles`, `synex_garages` und `synex_ui`. Ein Verzeichnisname belegt kein fertiges Feature. Der vorhandene Character-/Session-Lifecycle gehört zu `synex_core`.

## Einstieg

Das erste Kandidatenprofil benötigt Windows, FXServer-Build `35245`, `oxmysql 2.14.1`, MariaDB `11.8.8`, eine stabile eindeutige `synex_instance_id`, strikten Production-Modus und `deny_new`. Node.js `>=22.12.0` mit npm `>=10.0.0` wird für Repository-Tools und Tests benötigt, nicht für die Lua-Runtime.

```bash
git clone https://github.com/PixelGG/Synex_Framework.git
cd Synex_Framework
npm ci
npm run check
npm test
npm run security
npm run certify
```

Diese Befehle sind Entwicklungs-Gates und allein kein Production-Beta-Nachweis. Das Repository ist ein Entwicklungs-Monorepo und kein fertiges Server-Paket. Für den ersten Kandidaten dürfen nur `oxmysql` und `synex_core` deployed werden. Details stehen im [Getting-started-Guide](../../getting-started.md), in der [Core-Konfigurationsvorlage](../../../examples/server.cfg.example) und im [Release-Gate](../../release-readiness.md).

## Dokumentation

Englisch ist die kanonische technische Dokumentationssprache.

- [Dokumentationsindex](../../README.md)
- [Core-Production-Beta-Release-Gate](../../release-readiness.md)
- [Bekannte Grenzen](../../known-limitations.md)
- [Backup und Restore](../../backup-and-restore.md)
- [Architektur](../../architecture/README.md)
- [Public API](../../api/README.md)
- [Security](../../security/README.md)
- [Security Policy](../../../SECURITY.md)
- [Betrieb](../../operations.md)
- [Tests und CI](../../testing.md)

## Community

Entwicklungsdiskussionen, Implementierungsfeedback und Framework-Updates findest du in der offiziellen Synex-Community.

<p align="center">
  <a href="https://discord.gg/heJU5t2Hfa">
    <img src="../../../.github/assets/readme/discord-community.svg" width="720" alt="Dem offiziellen Synex-Discord beitreten">
  </a>
</p>

## Lizenz

Copyright &copy; 2026 PixelGG. Synex steht ausschließlich unter der [GNU Affero General Public License v3.0](../../../LICENSE).

---

<p align="center"><sub>Synex Framework &middot; Explizite Contracts. Verantworteter State. Ehrliche Grenzen.</sub></p>
