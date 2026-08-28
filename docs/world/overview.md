# World Semantics & Spatial Authority

`synex_world` answers bounded questions about what a position means and supplies primitive world operations to server resources. Static definitions stay in their owning resource; only selected dynamic state is persisted.

## Implemented scope

The current source contains:

- resource-owned, namespaced JSON world bundles with atomic activation and runtime revisions;
- a validated containment graph for regions, locations, interiors, rooms, zones, anchors, doors, portals, instance templates, map packages, IPL bundles and state definitions;
- point, sphere, axis-aligned box, rotated box, vertically bounded polygon and union geometry;
- a two-level spatial hash with bounded global fallback, candidate and result limits;
- server-resolved context and bounded nearby queries;
- semantic anchors without action or authorization logic;
- versioned runtime and persistent world state plus versioned door state;
- server-checked portal transitions with short-lived, single-use grants;
- in-memory instance lifecycle backed by `synex_entities` routing-bucket contracts;
- resource-state metadata for map packages and client-side IPL, interior-set and DoorSystem reconciliation;
- revisioned, size-bounded client slices and read-only client exports;
- repository, outbox, health, metric, audit and offline CLI primitives.

## Explicitly outside the domain

World does not own map assets, vehicle or inventory state, accounts, jobs, shops, housing rules, NPC AI, weather/time synchronization, HUDs, blips, prompts, interaction actions, smart-object leases or action graphs.

The important separations are:

```text
map/MLO resource        -> models, collision, textures, YMAP/YBN/YDR/MLO
companion resource      -> declarative Synex meaning and relationships
synex_world             -> validation, graph, geometry, context and typed bounded state
synex_entities          -> Entity identity, materialization and routing buckets
future synex_interact   -> player intent, prompts, leases and actions
gameplay domains        -> business rules and authorization intent
```

## Definition versus state

A bundle definition says that a door or location exists. It is immutable structural data owned by the declaring resource. Door state and `world_state_definition` values are runtime facts and may be in-memory or durable depending on the definition.

Static geometry, labels, model hashes and portal destinations are not copied into MariaDB. The current migration owns only world state, door state and an event outbox.

## Maturity

Automated schema, tooling and Lua runtime tests are present. They do not prove that Cfx natives, OneSync routing, client streaming or lifecycle cleanup work on a particular FXServer artifact. Promotion requires an exact-candidate live run with MariaDB, FXServer and a real client; that run has not yet been recorded for `synex_world`.
