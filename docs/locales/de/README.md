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
  <img alt="Core-Reifegrad: Production Beta" src="https://img.shields.io/badge/core-Production--Beta-8b73ff?style=flat-square&amp;labelColor=111827">
  <a href="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml?query=branch%3Amain"><img alt="Framework CI" src="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml/badge.svg?branch=main"></a>
  <a href="../../../LICENSE"><img alt="Lizenz: AGPL-3.0-only" src="https://img.shields.io/badge/license-AGPL--3.0--only-45c9a5?style=flat-square&amp;labelColor=111827"></a>
</p>

<p align="center">
  <img src="../../../.github/assets/readme/runtime-flow.svg" width="1200" alt="Modularer Synex-Runtime-Flow">
</p>

> [!IMPORTANT]
> **Synex Core — PRODUCTION BETA.** Der exakte `synex_core`-Kandidat hat das erste Core-only-Production-Beta-Profil bestanden. Synex `0.1.0` bleibt ein experimenteller Source-Release mit `experimental` markierten öffentlichen Contracts. Dies ist weder ein Stable-/1.0-Release noch eine Aussage zur frameworkweiten Reife oder ein allgemeiner Production-Support-Anspruch.

## Aktueller Prüfstand

`synex_core` hat die eingefrorene Production-Beta-Ziellinie am **25.08.2026** für das exakte Profil unten bestanden. Die Entscheidung gilt ausschließlich für Core-Commit `7ad4b72ee9bcd0a2a0481cfacfe5f807eb1b3ec5` und Core-Tree `9f0960f1e27fe43195ae4602cb2ef447cbc0509b`. Die aktuellen Core-Erweiterungen für Domain-Persistenz und koordinierte Löschung sind spätere Kandidatenarbeit und übernehmen diese Abnahme nicht.

| Abschlussarbeit | Aktueller Stand |
| --- | --- |
| Abschließender Datenbankausfall- und Recovery-Lauf | PASS |
| Vollständiger automatisierter Abschlusslauf | PASS — `npm run check`; 416 bestanden, 0 fehlgeschlagen, 19 erwartete Live-DB-Skips; Security: 0 Findings; Audit: 0 Schwachstellen |
| Synchronisierung der gesamten Repository-Dokumentation | PASS |
| Client-Smoke-Test: Join, Disconnect, Reconnect | PASS — geordnete neunstufige Join-Pipeline, sauberer Disconnect, Reconnect und finales Cleanup |
| Abschließender Diff- und Secret-Check; Commit und Veröffentlichung auf `main` | PASS |

- **PRODUCTION-BETA ABGENOMMEN.** Datenbankausfall-Recovery, automatisierter Abschlusslauf, Dokumentationssynchronisierung, Client-Smoke-Test, Abschlussprüfung und Veröffentlichungs-Gates sind für das exakte Core-only-Profil bestanden.
- **LIVE-CLIENT VERIFIZIERT.** Der Join durchlief alle neun Verbindungsstufen in der vorgesehenen Reihenfolge; anschließend folgten ein sauberer Disconnect und ein erfolgreicher Reconnect. Doctor meldete `PASS`, alle 26 Migrationen waren angewendet und das finale Cleanup hinterließ 3 geschlossene Sessions, 0 offene Sessions sowie 0 aktive Session- oder Admission-Leases.
- **BEGRENZTER REIFEGRAD.** Diese Abnahme macht Synex nicht zu Stable/1.0, zertifiziert nicht das gesamte Framework und ändert die öffentlichen Core-Contracts nicht von `experimental`.
- **NICHT ZERTIFIZIERT.** MySQL und Multi-Instance-Betrieb einschließlich `kick_old` gehören nicht zum abgenommenen Production-Beta-Profil.
- **AUSSERHALB DES SCOPES.** `synex_groups` und `synex_accounts` sind eigenständige Experimental-Alpha-Engines. `synex_entities` ist eine server-only Entity Authority Engine im Status Development / Experimental Alpha; ihre Repository-Implementierung ist vorhanden, die reale MariaDB-, FXServer-/OneSync-, Neustart-/Recovery-, Cluster-, Client-/Control- und exakte Kandidatenabnahme bleibt offen. `synex_world` ist eine Development-/Experimental-Alpha World-Semantics- und Spatial-Authority-Resource; ihre reale MariaDB-, FXServer-/OneSync-, Native-Client- und Neustartabnahme bleibt offen. Die read-only Domain-Projektionen in `synex_control` sind experimentell. `synex_bridge` ist als fail-closed Experimental-Alpha Compatibility Platform implementiert, aber noch nicht live abgenommen. `synex_ui` ist als Experimental-Alpha-UI-Foundation implementiert; die reale FiveM-/CEF-Abnahme bleibt offen. Die übrigen Resources, Libraries und Beispiele sind Rework-Snapshots oder Scaffolds. Keine dieser Komponenten gehört zur eingefrorenen Core-Zertifizierung.

Das optionale read-only `synex_control` ist als Development-/Experimental-Alpha-Operationsfläche mit automatisierten Provider-, Transport-, Sanitizer- und NUI-Quellprüfungen implementiert. Die reale FXServer-Provider-Lifecycle- sowie CEF-/Client-Smoke-Abnahme bleibt offen; die automatisierten Prüfungen sind keine Reifegrad-Hochstufung.

<details>
<summary>Post-Beta-Hardening — ausdrücklich kein Teil dieses Abnahme-Gates</summary>

- 125-Minuten-Soak
- permanenter Evidence-Runner
- historischer Upgrade-Drill
- ausführlicher Backup-/Restore-Drill
- zusätzliche nicht kritische ABI-Tests

Diese Prüfungen gehören zu den Arbeiten für den späteren Austritt aus der Beta. Sie erweitern die eingefrorene Production-Beta-Ziellinie nicht.

</details>

[Release-Gate](../../release-readiness.md) &middot; [Testabdeckung](../../testing.md) &middot; [Bekannte Grenzen](../../known-limitations.md)

### Abgenommenes Production-Beta-Profil

| Grenze | Abgenommener Wert |
| --- | --- |
| Produkt | ausschließlich `synex_core` |
| Host | Windows |
| Runtime | FXServer-Build `35245` |
| Datenbankadapter | `oxmysql 2.14.1` |
| Datenbank | MariaDB `11.8.8`, Session-Zeit in UTC |
| Topologie | eine aktive Core-Instanz |
| Production-Policy | `synex_environment "production"`, `synex_strict "1"`, `synex_duplicate_policy "deny_new"` |

Die Production-Beta-Entscheidung gilt nur innerhalb dieser Grenzen. Andere Plattformen, Abhängigkeitsversionen, Topologien oder Policies benötigen eigene Abnahmenachweise.

## Core-Beta-Scope

| Bereich | Pfad | Aktuelle Rolle |
| --- | --- | --- |
| Abgenommene Core-Runtime | [`synex_core`](../../../core/synex_core/) | Boot, Connection-/Session-/Character-Lifecycle, Contracts, RPC, Events, Hooks, Services, Capabilities, persistente Access-Policy, State, Reliability, Audit, Metrics, Health und eigene Migrationen |
| Contract-Pipeline | [`packages/contracts`](../../../packages/contracts/) | Kanonische Inputs und deterministisch generierte Runtime-/Referenzartefakte für die Core-Entwicklung |
| SDKs und Tools | [`packages`](../../../packages/) / [`tools`](../../../tools/) | Generierte Clients/Typen, Validierung, Migration, Security, Certification und Tests; keine separat zertifizierten Server-Features |

Nur `core/synex_core` ist für das exakte Profil oben als Production-Beta-ready abgenommen. Die öffentliche Core-API bleibt experimentell.

### Downstream-Reifegrenze

`synex_groups` ist die Experimental-Alpha-Organizations-Engine. Der aktuelle Quellkatalog enthält 71 Groups-Contracts und 31 Migrationen: 70 Contracts sind serverlokal, nur `synex.groups.self.snapshot` ist eine begrenzte, sitzungsgebundene Client-Projektion. Die frühere Live-Evidenz liegt vor Migration `032`; aktuelle Client-/Kandidaten-/Reifeprüfungen bleiben offen. `synex_accounts` ist nun eine server-only Experimental-Alpha Financial Engine mit 59 lokalen Contracts und 18 Migrationen. Der aktuelle Arbeitsstand bestand am 28.08.2026 den isolierten Datenbanklauf auf MariaDB 11.8.8 mit 104/104 Tests; FXServer-, Neustart-/Recovery-, Upgrade-, exakte Kandidaten- und Reifeabnahme bleiben offen. Accounts besitzt weder Client- noch NUI-Schnittstellen; Gameplay und UI gehören später zu `synex_banking`. `synex_entities` ist eine server-only Development-/Experimental-Alpha Entity Authority Engine mit 33 versionierten Contract-Definitionen über 32 Namen und vier eigenen Migrationen. Implementierung und Repository-Regressionen sind vorhanden; reale MariaDB-, FXServer-/OneSync-, Neustart-/Recovery-, Cluster-, Client-/Control- und exakte Kandidatenabnahme bleiben offen. `synex_world` enthält deklarative World Bundles, Graph/Geometrie, räumlichen Kontext, Doors, Portals, State, Instances und einen read-only Client-Cache, bleibt aber bis zur echten MariaDB-, FXServer-/OneSync-, Native-Client- und Neustartabnahme Development / Experimental Alpha. Die read-only Domain-Projektionen in `synex_control` sind implementiert, aber experimentell. `synex_bridge` besitzt getrennte QB-/QBX-/ESX-Provider, bleibt jedoch Experimental Alpha und ohne exakte FXServer-/Client-Abnahme. Alle späteren Ressourcen, übrigen Libraries und ausführbaren Beispiele bleiben Rework-Snapshots oder Scaffolds. Keine dieser Downstream-Komponenten gehört zur Core-Beta.

`synex_ui` ist als Experimental-Alpha-UI-Foundation mit einem Build-time-React-Paket und einer getrennten FiveM-Client-Runtime implementiert. Automatisierte Typ-, Unit-/Component-, Browser-, Build-, Transport- und Closed-State-Prüfungen ersetzen nicht die noch offene reale FiveM-/CEF-, Safe-Zone-, Controller-, Focus-Recovery-, Gameplay-Lesbarkeits- und Performance-Abnahme. Die UI erbt keine Core-Zertifizierung.

Das gilt auch für die reservierten Gameplay-Namen `synex_character`, `synex_identity`, `synex_inventory`, `synex_banking`, `synex_phone`, `synex_radio`, `synex_jobs`, `synex_shops`, `synex_vehicles` und `synex_garages`. Ein Verzeichnisname belegt kein fertiges Feature. Der vorhandene Character-/Session-Lifecycle gehört zu `synex_core`.

## Einstieg

Das abgenommene Production-Beta-Profil benötigt Windows, FXServer-Build `35245`, `oxmysql 2.14.1`, MariaDB `11.8.8`, eine stabile eindeutige `synex_instance_id`, strikten Production-Modus und `deny_new`. Node.js `>=22.12.0` mit npm `>=10.0.0` wird für Repository-Tools und Tests benötigt, nicht für die Lua-Runtime.

```bash
git clone https://github.com/PixelGG/Synex_Framework.git
cd Synex_Framework
npm ci
npm run check
npm test
npm run security
npm run certify
```

Diese Befehle sind Entwicklungs-Gates und allein kein Production-Beta-Nachweis. Das Repository ist ein Entwicklungs-Monorepo und kein fertiges Server-Paket. Für das abgenommene Profil dürfen nur `oxmysql` und `synex_core` deployed werden. Details stehen im [Getting-started-Guide](../../getting-started.md), in der [Core-Konfigurationsvorlage](../../../examples/server.cfg.example) und im [Release-Gate](../../release-readiness.md).

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
- [UI-Foundation](../../ui/README.md)
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
