# Semantic anchors

An anchor records that a meaningful point exists in the World. It does not define what a player may do there.

```json
{
  "kind": "anchor",
  "key": "synex_world_companion:site.reception",
  "parent": "synex_world_companion:site.lobby",
  "position": { "x": 0, "y": 0, "z": 0 },
  "radius": 0.75,
  "tags": ["synex.anchor.counter", "synex.example.reception"]
}
```

Without a positive radius, the compiler creates point geometry. A positive radius creates sphere geometry. Radius is bounded to `0..100`.

## Tags

Anchor categories are open, namespaced-style tags rather than hard-coded ATM/shop/police enums. Tags are lowercase, unique, sorted at compile time and bounded to 32 values of at most 64 bytes each.

Tags are semantic filters only. They are not access grants, group capabilities or proof of proximity.

## Optional Entity reference

An anchor may carry an `entityRef` with stable Entity ID and generation. The current compiler preserves that reference as metadata while retaining the declared static position for spatial indexing. World does not materialize the Entity, lease it, continuously move the anchor with a runtime handle or maintain the optional dynamic recovery-binding extension. A companion can replace its owner-fenced bundle with a new generation-safe `EntityRef`; stale bindings remain diagnosable while the semantic anchor definition survives.

## Client discovery

`exports.synex_world:NearbyAnchors()` reads only the current bounded client slice. It accepts either a numeric limit or:

```lua
local anchors = exports.synex_world:NearbyAnchors({
    limit = 16,
    tag = 'synex.anchor.counter',
    maxDistance = 25.0,
})
```

The maximum result count is 256 and maximum distance filter is 1,000. This export is for UX/discovery. A server operation must resolve the canonical object and validate current position/context again.

## Interaction boundary

A future interaction resource may attach prompts, intent and action graphs to anchor references. Those behaviors do not belong in an anchor definition and are not implemented by `synex_world`.
