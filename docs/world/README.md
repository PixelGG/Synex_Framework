# Synex World documentation

> [!WARNING]
> `synex_world` is **Development / Experimental Alpha**. Its schemas, contracts, runtime modules and automated tests are implementation evidence, not an accepted deployment. A real FXServer/OneSync run with a connected FiveM client—covering slice streaming, DoorSystem, IPL/interior reconciliation, transitions, routing buckets and restart cleanup—is still open.

`synex_world` is the resource-owned semantics and spatial-authority layer for Synex. It turns declarative world bundles into a revisioned graph, compiled geometry, bounded spatial queries, server-verified context, dynamic state and small client projections.

It is not an MLO loader, interaction menu, gameplay rules engine or replacement for Entity Authority. The [World domain ADR](../architecture/decisions/0008-world-domain-boundary.md) records those boundaries.

## Guide

- [Overview and maturity](overview.md)
- [Architecture](architecture.md)
- [Server API and contracts](api.md)
- [World graph and references](world-graph.md)
- [Declarative bundles and ownership](bundles.md)
- [Geometry](geometry.md) and [spatial index](spatial-index.md)
- [Locations, regions and zones](locations.md)
- [Interiors and rooms](interiors.md)
- [Semantic anchors](anchors.md)
- [Doors](doors.md)
- [Portals](portals.md)
- [Instances](instances.md)
- [Dynamic world state](state.md)
- [Access evaluation](access.md)
- [Map packages, IPLs and interior sets](map-packages.md)
- [Client context and slices](client-context.md)
- [Security boundary](security.md)
- [Operations and diagnostics](operations.md)
- [Testing and open acceptance](testing.md)
- [Companion-resource development](development.md)

## Canonical artifacts

- [`world-bundle.schema.json`](../../schemas/world-bundle.schema.json) is the closed JSON Schema for declarative bundles.
- [`world.contracts.json`](../../resources/synex_world/contracts/world.contracts.json) is the source for the experimental mutation contracts.
- [`limits.lua`](../../resources/synex_world/shared/limits.lua) contains the runtime safety bounds.
- [`synex_world_companion`](../../examples/synex_world_companion/README.md) is the minimal companion-resource example.

`world.contracts.json` remains the canonical source for exact request, response and error shapes. Generated contracts and SDK files are deterministic projections of that source. This guide explains the architecture; it does not replace the schema.
