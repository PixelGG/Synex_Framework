# Client context and spatial slices

The client receives a bounded read model for UX and local discovery. It never receives the full registry and never becomes a security authority. `GetContext()` always labels this cached projection `authority = "OBSERVED"`, even though its last source slice was server-produced; only a fresh server-side resolution/verification is `VERIFIED`.

Treat every client export and local event as `OBSERVED`. Server context resolution and the debounced presence events are `VERIFIED` from the server-observed player position, but even those labels do not replace operation-specific capability, revision, instance and state checks.

## Slice contents

A current slice may include:

- verified server context and bundle revisions;
- nearby regions, locations, interiors, rooms, zones, anchors, doors and portals;
- current projected door state;
- bounded desired IPL and interior-entity-set requirements with server-aggregated reference counts;
- up to 64 schema-validated state projections relevant to the current global/context/instance scopes.

Every bounded one-second server tick resolves context again from the server-observed position and advances Presence debounce. The server rebuilds a slice when its fingerprint changes: fine spatial cell, semantic context signature, instance, registry revision, map-registry generation, or at least four units of movement from the last slice origin. This detects semantic boundaries and material nearby changes inside one spatial cell without rebuilding for sub-threshold jitter. A rebuild queries a 204-unit safety envelope around the canonical 200-unit slice radius, so movement below the four-unit threshold cannot omit an object that has just entered the canonical radius; projected distance drift remains bounded by the same threshold. Each slice remains capped at 512 objects and 48 KiB encoded JSON. Per-kind client limits further constrain the accepted payload.

Every incoming slice must have schema version 1, an increasing revision, closed top-level keys, dense bounded lists, finite coordinates, valid keys/tags, bounded nesting/string bytes and valid encoded size. Invalid messages are ignored.

Because state reads may yield through the database port, the server re-reads the active session immediately before delivery. A changed session ID or source generation discards the completed payload, preventing a slice built for an old connection from reaching a reused player source.

Incremental door messages carry three distinct values: the client-stream revision, the immutable definition revision and the optimistic door `stateVersion`. The client applies an update only to the matching definition and only when its state version advances.

## Read-only exports

```lua
local context = exports.synex_world:GetContext()
local location = exports.synex_world:CurrentLocation()
local room = exports.synex_world:CurrentRoom()
local anchors = exports.synex_world:NearbyAnchors({ limit = 16, maxDistance = 30.0 })
local doors = exports.synex_world:NearbyObjects('door', { limit = 16, maxDistance = 30.0 })
local portals = exports.synex_world:NearbyObjects('portal', { limit = 16, maxDistance = 30.0 })
local door = exports.synex_world:ResolveCached('door', 'synex_world_companion:site.front_door')
```

All returned tables are copies. `NearbyObjects` accepts only `anchor`, `door` or `portal`, reads only the bounded current slice and supports the same `limit`, `tag` and `maxDistance` filters as `NearbyAnchors`. `ResolveCached` only searches the current per-kind slice index.

## Local events

The client emits local presentation events when an accepted slice changes:

- `world:contextChanged(next, previous, revision)`;
- `world:locationChanged(next, previous, revision)`;
- `world:roomChanged(next, previous, revision)`;
- `world:instanceChanged(next, previous, revision)`.

They are local notifications, not network mutation endpoints.

## Native reconciliation and cleanup

Door, IPL and interior-set desired state is reconciled every 250 ms. Resource stop clears pending transitions and cached slices, and removes/deactivates only native registrations made by this runtime. No `Wait(0)` global World scan or client-to-server mutation event exists.

The automated client harness covers payload rejection, revision behavior, exports, native reconciliation, cleanup and server-only transition messages. A real client live test is still required before release acceptance.
