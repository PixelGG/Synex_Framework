# Candidate pipeline

Candidate discovery deliberately separates cheap broadphase work from expensive line-of-sight work.

## Sources

The runtime can project candidates from:

- exact `worldRef` bindings for nearby World anchors, doors and portals;
- legacy `worldAnchor` bindings, normalized as anchor `WorldRef` candidates;
- exact `entityRef` bindings;
- `entityArchetype` and `entityBone` bindings matched to a ray-observed entity;
- `staticTransform` definitions in the client spatial index;
- resource-owned bounded `actor`, `dynamic` or `ephemeral` providers.

Provider registration is owner/epoch-bound, namespaced and capped. `actor`, `dynamic` and `ephemeral` describe the client discovery source and share the same closed output envelope. Each result must still resolve to a declared `dynamic` Smart Object binding; the server-side owner provider then resolves and validates the canonical target again. Provider-supplied `netId`, model or position data never becomes persistent identity or authority. Slow or malformed output is ignored rather than promoted to authority.

## Bounded stages

1. Read one actor and camera snapshot.
2. Query only nearby spatial cells and bounded `synex_world` anchor/door/portal slices.
3. Match a ray-observed entity to indexed Entity definitions; do not scan global entity pools.
4. Admit provider candidates until the total candidate cap is reached.
5. Rank cheaply by gaze, distance and exact-ray evidence.
6. Apply cached or asynchronous LOS work only to the most relevant subset.
7. Hand the bounded set to the Intent Engine.

Current hard limits include 128 candidates per sample and eight candidates eligible for expensive work. The registry may be much larger than the local hot path; global registry size must never become per-frame work.

## Hits and bones

Candidates retain a canonical target reference, binding/object/slot identity, distance, gaze, exact-ray/occlusion state and presentation data. World candidates retain the exact kind, key and revision. Bone lookup affects the local hit point only. The current `entityBone` binding has no fallback mode: a missing native bone index rejects that local candidate and cannot manufacture Entity authority.

## Async ray lifecycle

Only one pending shape test is tracked at a time. Pending results remain pending, completed results update a short-lived LOS cache, and stale cache entries are removed. There is no synchronous busy-wait. Exact native behavior remains part of the [live test gate](testing.md).
