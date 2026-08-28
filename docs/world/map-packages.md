# Map packages, IPLs and interior sets

World describes its dependency on map content; it does not contain or redistribute that content.

## Map package

A `map_package` records:

- the Cfx resource name;
- package type: `mlo`, `ymap`, `ipl`, `interior` or `custom`;
- expected resource state (currently only `started`);
- an optional canonical semantic version without build metadata;
- dependent Cfx resources;
- associated World locations;
- optional IPL-bundle references;
- a `required` diagnostic flag.

Resource and dependency names use the same bounded Cfx-resource-name grammar as the runtime compiler. In particular, empty segments such as `map..asset` are rejected instead of being treated as valid resource identifiers.

Availability checks `GetResourceState` for the package resource and every declared dependency. A package applies to locations listed by the package and to objects that reference it directly. That dependency propagates through the validated parent/containment graph, so a child room, anchor, door or portal cannot remain available after its parent map becomes unavailable. The derived dependency index is rebuilt only when the registry revision changes; resource-state changes invalidate the availability result cache. Internally, unchanged inherited failure-reason sets are shared across descendants while every public result remains a detached copy. Unavailable objects are omitted from available-only context and slices. `required` contributes to the unavailable-required summary; it does not make an unavailable object available.

The bounded Control map-package view and runtime Doctor attach a cold-path impact summary. It counts affected bundles, locations, anchors and doors and returns at most eight sorted sample keys per category. Counts remain explicit when samples are truncated; this diagnostic does not mutate or restart the map resource. Full impact results are revision-cached in a fixed 256-entry least-recently-used cache. A Doctor pass performs at most two uncached impact analyses and marks later outage findings `impactDeferred`; Control can request another exact package on demand.

A Cfx resource state of `started` is metadata evidence only. It does not prove that collision, an IPL, a door entity or an interior is already streamed on a particular client.

## IPL bundle

An `ipl_bundle` contains 1–64 IPL names, a scope value (`global`, `context` or `instance`) and up to 32 interior entity sets. Global bundles are always included. Context bundles are included when referenced by a projected object. Instance bundles additionally require a current World instance. The server aggregates duplicate IPL names and `(interiorId, name)` pairs into deterministic desired entries with an exact reference count. Counts are bounded at 255; a count overflow, more than 64 desired IPLs, more than 128 desired interior sets or conflicting colors for one shared set fails the slice closed.

The client:

- requests a missing IPL and retries at a bounded interval;
- keeps a shared IPL/entity set active while its server-projected reference count remains positive and releases it only after the final reference leaves the desired slice;
- removes an IPL only if this runtime requested it and it is no longer desired;
- activates and optionally colors valid interior entity sets;
- refreshes an interior after a change;
- deactivates only sets activated by this runtime.

These operations run every 250 ms, not every frame. They use client-only natives and remain unaccepted until tested with a real FiveM client and the actual target map.

## Companion pattern

Keep purchased/custom map assets unchanged. Put the World bundle in a separate companion resource and reference the map's resource name through `map_package`. See the [development guide](development.md) and [example](../../examples/synex_world_companion/README.md).
