# Security development and verification

## Resource layout

```text
resources/synex_security/
├── client/sentinel.lua
├── config/default.json
├── contracts/security.contracts.json
├── migrations/001_security.sql
├── shared/{limits,validation}.lua
├── server/
│   ├── {signals,expectations,correlation,cases,enforcement}.lua
│   ├── {sentinel,movement,detectors,cfx_guards,hardening}.lua
│   ├── {database,repository,observability,diagnostics}.lua
│   └── {control_provider,service,runtime,server}.lua
├── fxmanifest.lua
└── synex.resource.json
```

## Extension rules

- Add a detector for a generic capability, never a product/menu name.
- Keep prevention in the owning Core/domain handler.
- Emit only after the authoritative decision, with bounded evidence.
- Use an existing server authority or inject a narrow adapter; do not create a
  parallel account, entity, world, interaction, or ban store.
- Treat client and NUI values as hostile and advisory.
- Add an expectation kind only when several domains need the semantic state;
  matching must still use explicit selectors.
- Attach shared root/request/trace identity to derived signals.
- Bound every registry, window, list, string, depth, and payload.
- Clean player state on drop/source reuse and owner state on resource restart.
- Do not expose a mutation through Control.

## Repository checks

Run the commands already defined by the repository:

```powershell
npm run check
node tools/test-runner.mjs security
npm run security
npm test
```

The focused Security tests currently cover canonical validation and
deduplication, expectation ownership/TTL/revision, correlation independence and
decay, case lifecycle/persistence projections, enforcement policy/idempotency,
Core Access bounds, nonterminal-decision quarantine/restart recovery,
Sentinel retry/sequence/freshness/liveness, movement patterns, player integrity,
Cfx guard ports, and the read-only hardening advisor.

These are pure Lua/Wasmoon and injected-port tests. They do not prove a live
FiveM server.

## Mandatory live matrix

Before any maturity promotion, test on the exact target FXServer artifact:

1. clean MariaDB migration and restart recovery;
2. Core binding, service/contract registration, health transitions, and Core
   restart rebind;
3. join, Sentinel bootstrap, retry, disconnect, reconnect, source reuse, and
   resource restart cleanup;
4. expectation registration, expiry, update/revoke, owner stop, and owner-epoch
   replacement;
5. representative World portal and Interact-denial integrations;
6. `entityCreating` payloads/cancellation for client and server creation across
   routing buckets;
7. `weaponDamageEvent` and `explosionEvent` payloads, rate windows, and
   cancellation;
8. `startProjectileEvent` and `ptFxEvent` delivery and cancellation separately,
   with cancellation kept disabled until confirmed;
9. movement/player-integrity scenarios including spawn, death, respawn,
   interiors, vehicles, streaming, custom models, and admin/medical states;
10. case persistence, duplicate replay, `DECIDED` crash injection,
    `INDETERMINATE` operator review, retention, degraded database behavior, and
    bounded recovery;
11. subject changes between decision and action;
12. Core Access delegation using an isolated test identity and reversible
    operator procedure;
13. resmon/CPU/memory behavior under legitimate and abusive event volume.

Record both positive detections and legitimate negative/control cases. A test is
blocked, not passed, when the target event cannot be generated or observed.

`synex doctor security` exposes fixed, bounded checks for service availability,
detector health, Sentinel transport, stale expectations, orphaned active case
references, correlation backlog, entity/game-event hooks, Core signal ingestion,
and Core Access integration. Advisory findings do not silently change detector
or enforcement configuration.

## Release gate

`synex_security` is currently **Experimental / Alpha** and observe-first. Do not
enable automatic kick/ban, claim production stability, or treat
`startProjectileEvent`/`ptFxEvent` cancellation as supported until the live
matrix passes on the deployed artifact and the false-positive review is signed
off.
