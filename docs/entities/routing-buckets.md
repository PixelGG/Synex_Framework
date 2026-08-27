# Routing buckets

`synex_entities` manages bounded routing-bucket lifecycles for server resources. A managed bucket reference contains both the numeric Cfx bucket ID and an opaque generation:

```lua
{
    bucket = 1204,
    generation = 'bucket-generation-token',
}
```

Bucket `0` is the default world and always uses generation `0`. A nonzero numeric ID can be reused only with a new generation, so an old reference returns `STALE_BUCKET`.

Routing buckets are session/game-mode dimensions. They are not an interior, MLO, housing, location or door system.

## Profiles

Bucket creation v2 supports:

| Profile | Lockdown | Population |
| --- | --- | --- |
| `isolated_strict` | `strict` | disabled |
| `session` | `strict` | disabled |
| `character_selection` | `strict` | disabled |
| `custom` | caller-selected `strict`, `relaxed` or `inactive` | caller-selected |

Every bucket also has purpose, per-bucket Entity/player capacity, owner resource, resource epoch, creation time, optional UTC expiry and health. Preset policy cannot be overridden. Custom policy remains bounded by the server-wide configured maxima.

The retained v1 create contract maps to the strict isolated policy for compatibility; v2 exposes the full profile object.

## Ownership and movement

Only the owning resource in its current lifecycle epoch can destroy a bucket or move an Entity/player into it. Entity moves require a current resource-owned `EntityRef` and the target bucket generation. Persistent moves are committed under the Entity authority lease; a database failure attempts to restore the previous runtime bucket.

Player movement additionally verifies the current Core player session ID and source generation before and after the native move. This prevents a reused numeric source from inheriting an earlier player's bucket assignment. A resource cannot take over another resource's managed assignment, and an unmanaged nonzero current bucket fails closed.

Observed `onEntityBucketChange` and `onPlayerBucketChange` events are matched against a short-lived authorized-move marker. An out-of-band move is audited and reverted to the Synex-tracked bucket. A failed revert degrades health.

## Capacity and destruction

Creation is bounded globally and per resource. Spawn admission reserves Entity capacity for the target bucket; player moves enforce player capacity.

Destroying or expiring a bucket runs a bounded cleanup:

1. stop new spawns into the bucket;
2. return tracked players to bucket `0`;
3. move persistent Entities to bucket `0` under authority;
4. delete temporary Entities;
5. verify no tracked occupant remains;
6. restore population/lockdown defaults and release the numeric bucket.

Foreign occupants, an expired deadline, native failure or residual tracking blocks completion and degrades the bucket/resource rather than silently discarding ownership.

## Global server policy

Entity diagnostics may read `onesync`, `sv_entityLockdown`, `sv_filterRequestControl` and `sv_stateBagStrictMode` to report observations or recommendations. The resource does not change these ConVars. Operators must review global policy against the complete resource stack and current Cfx documentation.
