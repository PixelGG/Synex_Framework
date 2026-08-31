# ADR-0008: World semantics and spatial-authority boundary

Status: Accepted

## Context

Gameplay resources need a common vocabulary for locations, rooms, zones, anchors, doors, portals and instances. Storing those facts independently in each script creates conflicting coordinates, linear scans, incompatible door state and client-authoritative shortcuts. At the same time, map assets, Entity lifecycle, permissions and interaction actions already belong to different technical or domain owners.

## Decision

Adopt `synex_world` as the resource-owned, declarative World Semantics & Spatial Authority layer.

World owns:

- namespaced definitions, containment graph and revisioned references;
- geometry compilation, bounded spatial indexing and server-resolved context;
- semantic anchors, door definitions/state, portals and primitive world state;
- instance orchestration through generation-fenced `synex_entities` bucket contracts;
- map-resource metadata plus bounded client projections for DoorSystem/IPL/interior reconciliation;
- World diagnostics, health, audit and bounded Control read models.

World does not own:

- YMAP/YBN/YDR/MLO, collision, textures or purchased map files;
- Entity identity/materialization or routing-bucket authority;
- Groups policy data, accounts, inventory, vehicles, jobs or other business state;
- prompts, input, interaction leases, actions or action graphs;
- client state as authorization evidence.

Map semantics live in a separate companion resource. Static definitions remain with that resource and are not copied into MariaDB. Only schema-defined dynamic values and door state may be persistent.

All privileged mutation remains server-only through Core contracts/capabilities. Player-sensitive operations recompute position/context from server state. Cross-domain work uses public Core/Groups/Entities ports and never direct foreign-table SQL.

## Consequences

- One invalid object rejects an entire candidate bundle activation.
- Owner resource and epoch fence structural changes and cleanup.
- Hot reload changes revisions; stale `WorldRef` values fail closed.
- Frequent runtime queries use compiled spatial candidates rather than a complete registry scan.
- Clients receive only bounded local slices for UX and native reconciliation.
- `synex_interact` can consume revisioned anchors, doors, portals and context without moving action semantics into World.
- Third-party MLOs remain unmodified and can gain Synex meaning through a small companion.

This ADR accepts the domain direction only. `synex_world` remains Experimental Alpha until its exact candidate completes MariaDB, FXServer/OneSync, real-client and restart/recovery acceptance.
