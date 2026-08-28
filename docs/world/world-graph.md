# World graph and references

World objects use stable namespaced keys and optional containment parents. The namespace of every object and bundle must equal its owning resource, for example `synex_world_mrpd:mrpd.lobby`.

## Object kinds

| Kind | Spatial | Valid parent kinds |
| --- | --- | --- |
| `region` | yes | `region` |
| `location` | yes | `region` |
| `interior` | yes | `location` |
| `room` | yes | `interior` |
| `zone` | yes | `region`, `location`, `interior`, `room` |
| `anchor` | yes | `region`, `location`, `interior`, `room`, `zone` |
| `door` | yes | `location`, `interior`, `room`, `zone` |
| `portal` | yes | `region`, `location`, `interior`, `room`, `zone` |
| `world_state_definition` | no | `region`, `location`, `interior`, `room` |
| `instance_template` | no | none |
| `map_package` | no | none |
| `ipl_bundle` | no | none |

Missing parents, invalid parent kinds, duplicate keys and containment cycles reject the candidate bundle set.

## `WorldRef`

Runtime-sensitive APIs use:

```json
{
  "kind": "door",
  "key": "synex_world_mrpd:front_door",
  "revision": 18
}
```

`revision` is the active signed 31-bit registry revision assigned when that object's bundle was activated. Registry revisions are partitioned by the current Core-issued `synex_world` owner epoch, so a fresh World resource process cannot reuse the preceding process's range while Core remains active. A mismatched or deactivated reference fails with `STALE_WORLD_REF`; callers must resolve a fresh reference instead of silently retrying the old one. `WorldRef` values are runtime references and must not be persisted across a complete server lifecycle.

## Cross-resource references

A bundle may reference an object owned by another resource only when the target owner appears in the bundle's `dependencies` array. References are validated against the combined active catalog, and active resource-dependency cycles are rejected.

The graph does not transfer ownership. Only the owner resource and matching epoch can replace or unregister its bundle.

## Context ordering

At one coordinate, runtime results are ordered by kind (`zone`, `room`, `interior`, `location`, `region`) and then key. Context preserves every matching zone and region. For the singular hierarchy, the most specific matching room/interior/location wins, with key order as the same-kind tiebreaker; its validated parent chain supplies the remaining singular interior, location and region references. The implementation does not expose an author-defined priority field.
