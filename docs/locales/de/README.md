<p align="center">
  <img src="../../../.github/assets/branding/synex-mark.svg" width="88" height="88" alt="Synex Markenzeichen">
</p>

<h1 align="center">Synex</h1>

<p align="center">
  <strong>Eine contract-first FiveM-Runtime und Foundation für unabhängig verantwortete Resources.</strong>
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
  <img alt="Release: 0.1.0 experimental" src="https://img.shields.io/badge/release-0.1.0%20experimental-8b73ff?style=flat-square&amp;labelColor=111827">
  <a href="../../../LICENSE"><img alt="Lizenz: AGPL-3.0-only" src="https://img.shields.io/badge/license-AGPL--3.0--only-45c9a5?style=flat-square&amp;labelColor=111827"></a>
</p>

<p align="center">
  <a href="https://discord.gg/heJU5t2Hfa">
    <img src="../../../.github/assets/readme/discord-community.svg" width="720" alt="Dem offiziellen Synex-Discord beitreten">
  </a>
</p>

<p align="center">
  <img src="../../../.github/assets/readme/hero.webp" width="1200" alt="Abstrakte modulare Synex-Netzwerkdarstellung">
</p>

> [!CAUTION]
> **Experimenteller Source-Release.** Synex `0.1.0` enthält ausführbare Foundation-Resources, generierte Contracts, Migrationen, Tests und Tools. Alle öffentlichen Contracts sind weiterhin `experimental`; es gibt noch keinen stabilen Release, Paket-Installer oder Production-Support-Anspruch.

## Implementierte Foundation

| Bereich | Modul | Tatsächlich vorhandene Verantwortung | Status |
| --- | --- | --- | --- |
| Kernel | [`synex_core`](../../../core/synex_core/) | Boot-, Session- und Character-Lifecycle; Contracts, RPC, Events, Hooks, Services, Capabilities, persistentes RBAC/Access, State, Reliability, Audit, Metrics und Health | Experimental |
| Groups | [`synex_groups`](../../../resources/synex_groups/) | Persistente Groups, Grades, Capability-Regeln, Primary-Auswahl und versionierte Memberships | Experimental |
| Accounts | [`synex_accounts`](../../../resources/synex_accounts/) | Währungen, Double-Entry-Accounts, Holds, Access-Rollen, Reversals und Integrity-Read-Models | Experimental |
| Entities | [`synex_entities`](../../../resources/synex_entities/) | Server-authoritative Entity-Identität, Persistenzauflösung und Routing Buckets | Experimental |
| Betrieb | [`synex_control`](../../../resources/synex_control/) | Read-only In-Game-NUI mit begrenzten Core-/Domain-Ansichten, exakter Audit-Suche und transparentem geschlossenen Zustand | Experimental |
| Kompatibilität | [`synex_bridge`](../../../libraries/synex_bridge/) | Optionale, consumer-gebundene QB/QBX/ESX-Adapter mit begrenzten Callbacks, Cash-/Bank-Transfers und geprüftem Offline-Import | Experimental / Übergangspfad |
| Entwicklung | [`packages`](../../../packages/) / [`tools`](../../../tools/) | Generierte Lua-/TypeScript-SDKs, CLI, Analyzer, Certification und Tests | Experimental |

Die Kompatibilitätsadapter stellen keine veränderbaren Legacy-Playerobjekte bereit. Geldänderungen laufen ausschließlich als ausgeglichene Synex-Transfers über konfigurierte Gegenkonten; fehlende oder mehrdeutige Accounts schlagen geschlossen fehl.

Synex bindet API-Fassaden an die tatsächliche aufrufende Resource und deren Start-Epoch. JSON-Contracts definieren Version, Schema, Capability und Netzwerk-Richtung. Migrationen und Tabellen besitzen genau einen Domain-Owner. Client- und NUI-Eingaben bleiben nicht vertrauenswürdig.

### Nur reservierte Grenzen

`synex_character`, `synex_identity`, `synex_inventory`, `synex_banking`, `synex_phone`, `synex_radio`, `synex_jobs`, `synex_shops`, `synex_vehicles`, `synex_garages` und `synex_ui` enthalten derzeit nur Scaffolds und sind **keine ausführbaren Features**. Der aktuell vorhandene Character-/Session-Lifecycle liegt in `synex_core`.

## Einstieg

Benötigt werden ein aktueller FXServer, MariaDB/MySQL über `oxmysql >= 2.14.1` (bei aktiviertem `synex_entities` zusätzlich `< 3.0.0`), eine stabile `synex_instance_id` im strikten Production-Modus und OneSync `on` für `synex_entities`. Node.js wird für Repository-Tools und Tests benötigt, nicht für die Lua-Runtime.

```bash
npm ci
npm run check
npm test
npm run security
npm run certify
```

Dieses Repository ist ein Entwicklungs-Monorepo und kein fertiges Server-Paket. Resource-Platzierung, Konfiguration, Migrationen, Startreihenfolge und Grenzen stehen im [Getting-started-Guide](../../getting-started.md).

## Dokumentation

Englisch ist die kanonische technische Dokumentationssprache.

- [Dokumentationsindex](../../README.md)
- [Architektur](../../architecture/README.md)
- [Public API](../../api/README.md)
- [Security](../../security/README.md)
- [Betrieb](../../operations.md)
- [Tests und CI](../../testing.md)
- [Kompatibilität](../../compatibility/README.md)

## Lizenz

Copyright &copy; 2026 PixelGG. Synex steht ausschließlich unter der [GNU Affero General Public License v3.0](../../../LICENSE).

---

<p align="center"><sub>Synex Framework &middot; Explizite Contracts. Verantworteter State. Ehrliche Grenzen.</sub></p>
