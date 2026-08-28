# Regions, locations and zones

These objects provide semantic context around compiled geometry.

## Regions

A `region` is a large semantic area and may be parented by another region. Every region requires geometry. Multiple matching regions are retained in `WorldContext.regions`.

## Locations

A `location` is a concrete semantic place and may be parented by a region. It also requires geometry. Multiple disconnected shapes can be expressed with a `composite` union; there is no separate multi-geometry field.

Locations may reference:

- `mapPackages` that must be available before the object enters normal context/slice queries;
- `iplBundles` that describe client streaming requirements;
- children such as interiors, zones, anchors, doors, portals and state definitions.

## Zones

A `zone` is an overlapping geometric classifier beneath a region, location, interior or room. All matching zones remain in the resolved context and are sorted by key. Overlap with a location or room is expected and is not itself an error.

Zone tags carry meaning, not permission. A tag such as `synex.secure.evidence` does not authorize access.

## Context behavior

Map-unavailable objects are omitted from the normal available-only context. When semantic branches overlap, the runtime first selects the most specific matching primary object (`room`, then `interior`, then `location`; key order breaks a same-kind tie) and derives the singular room/interior/location/region fields from that object's validated parent chain. This prevents a canonical context from mixing unrelated overlapping hierarchies. All matching regions and zones remain available in their plural lists. The runtime has no bundle `priority` field, so avoid ambiguous same-kind overlaps when domain policy requires a different winner.

Location and room entered/left presence events use context resolved from the server-observed position on each bounded one-second World tick. The current presence tracker applies a 500 ms debounce and a 1,000 ms minimum dwell before changing stable presence. Repeated observations advance that state even when the client slice itself is unchanged.
