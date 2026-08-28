# Testing and open acceptance

`synex_world` is an Experimental Alpha candidate. Checked-in automated suites are implementation evidence; they are not a live-runtime release decision.

## Checked-in automated coverage

The repository contains focused coverage for:

- geometry primitives, invalid/fuzzed geometry and deterministic containment;
- graph/registry ownership, atomic activation, conflicts, cycles, revisions and stale references;
- deterministic coherent-hierarchy context resolution, fail-closed overlap bounds and large synthetic spatial-index bounds;
- graph-propagated map availability with shared descendant failure metadata, fixed impact-cache eviction and deterministic bounded outage impact shared by Doctor and Control;
- composable access gates, spoofed/stale context rejection and disabled-door denial;
- portal proximity/context/access/map checks, bounded grant capacity/replay/expiry cleanup and instance transition orchestration;
- direct instance create/join map and definition fences, server-owned template exits, source-generation rejection, post-move compensation and close/drain exit projection;
- signed `GetGameTimer` wrap handling for client transitions, portal grants and empty-instance TTLs;
- lifecycle-scoped durable mutation receipts that reject stale success after a simulated World restart;
- a fresh World runtime successor that receives a distinct owner-epoch revision range and starts without duplicate definitions, stale registrations, client slices or instances;
- rotating Doctor scan/impact/entity-authority budgets without full-catalog allocation per pass;
- instance cleanup policies, capacity/lifecycle fences, instance-scoped state cleanup and bounded orphan-bucket recovery after a lost create response or failed destroy;
- runtime and persistent state, door state, optimistic concurrency, provenance and transactional outbox writes;
- outbox claims, retry and terminal delivery handling;
- debounced presence, transient boundary-jitter suppression and same-cell semantic boundary changes without redundant slice sends;
- client slice validation, revision handling, read-only exports, DoorSystem/IPL/interior desired-state reconciliation and cleanup;
- a deterministic headless microbenchmark over the actual spatial-index, Context, registry and Access modules with 50,000 Anchors, 10,000 Zones, 5,000 Doors and 1,000 Locations;
- World migration ownership plus offline schema/CLI validation.

These tests use deterministic local adapters or a Lua harness where appropriate. They do not prove Cfx native behavior, OneSync routing, resource scheduling or MariaDB behavior for the exact deployable candidate.

## Optional extension limitation

The current source and documentation intentionally retain this non-blocking limitation:

- `autoRelockSeconds` is an optional convenience. Its bounded schedule is process-local and is not reconstructed for a persistent unlocked door after restart; the persisted semantic door state itself is restored normally.

Durable timer deadlines and recovery workers are outside the current Alpha acceptance scope. They require explicit persistence and recovery semantics rather than silently extending the existing door-state contract.

The optional visual developer overlay described in the design plan is not part of this candidate. No overlay is enabled in production or development by default; inspection is provided through the bounded Control and CLI views.

The checked-in benchmark covers `queryAt`, `queryNearby` at 10 m and 100 m, coherent Context resolution, Anchor resolution, Door resolution and Access. World iterations are capped at 5,000. It runs in an embedded Wasmoon VM with deterministic in-memory ports, not FXServer, FiveM natives, OneSync scope/replication, MariaDB, Cfx transport, a real client, workers or concurrency; its results are local regression evidence only.

## Required live run

Before any maturity promotion, deploy the exact candidate with its real manifest and policy to disposable MariaDB and FXServer/OneSync infrastructure, then connect a real FiveM client. Exercise at minimum:

1. fresh migration and resource boot;
2. companion discovery, replacement, stop/start and stale-reference behavior;
3. server-observed context and debounced presence while crossing boundaries;
4. DoorSystem leaves plus map stop/restart, including removal and restoration of child rooms, anchors, doors and portals;
5. shared IPL and interior-entity-set acquisition/release;
6. physical, teleport and instance portal flows, including denial, replay/expiry behavior and bucket cleanup;
7. disconnect/reconnect, Core/World/owner restarts and failure recovery;
8. persistent state/door restore and outbox recovery;
9. malformed or spoofed client messages and verification that no client-to-server mutation endpoint exists.

Until that run is recorded, client-native and OneSync behavior remains **open** even when repository tests pass.
