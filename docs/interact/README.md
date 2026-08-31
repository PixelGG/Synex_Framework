# Synex Interact documentation

> [!WARNING]
> `synex_interact` is **Experimental / Alpha**. The checked-in runtime, schemas and automated tests are implementation evidence, not a deployment or production-readiness decision. Exact FXServer/OneSync, real-client, CEF, restart and measured-performance acceptance is still required.

`synex_interact` is the context-aware interaction and gameplay-orchestration runtime for Synex. It discovers a small local candidate set, selects one primary intent, asks the server for an actor/target/intent/revision-bound lease, and runs a bounded Action Graph only after server authorization.

The two governing rules are:

> **The player should interact with the world, not with a targeting UI.**

> **The client discovers. The server authorizes.**

## Guide

- [Overview and maturity](overview.md)
- [Architecture](architecture.md)
- [Context Sensor](context-sensor.md)
- [Candidate pipeline](candidate-pipeline.md)
- [Intent Engine](intent-engine.md)
- [Smart Objects](smart-objects.md)
- [Slots](slots.md) and [reservations](reservations.md)
- [Interaction leases](leases.md)
- [Interaction sessions](sessions.md)
- [Action Graphs](action-graphs.md)
- [Actor locks](actor-locks.md) and [cancellation](cancellation.md)
- [Interaction bundles](bundles.md)
- [`synex_world` integration](world-integration.md)
- [`synex_entities` integration](entities-integration.md)
- [`synex_ui` presentation](ui.md)
- [Security model](security.md)
- [Compatibility boundary](compatibility.md)
- [Performance model](performance.md)
- [Development guide](development.md)
- [API and contract reference](api.md)
- [Testing and open acceptance](testing.md)

## Canonical artifacts

- [`interaction-bundle.schema.json`](../../schemas/interaction-bundle.schema.json) is the closed authoring schema.
- [`interact.contracts.json`](../../resources/synex_interact/contracts/interact.contracts.json) is the canonical source for the 12 experimental contracts.
- [`limits.lua`](../../resources/synex_interact/shared/limits.lua) contains hard runtime bounds and adaptive sensor intervals.
- [`terminal.interact.json`](../../resources/synex_interact/interactions/terminal.interact.json) is the resource-local bounded integration fixture.
- [`synex_interact_companion`](../../examples/synex_interact_companion/README.md) pairs a real World Anchor declaration with an Interaction bundle and no gameplay domain.

The schema and contract descriptor remain authoritative for exact field shapes. These guides explain ownership and integration; they do not widen the accepted vocabulary.
