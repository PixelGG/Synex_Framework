# Entity authority and routing buckets

> [!WARNING]
> `synex_entities` is an experimental rework snapshot. It is unsupported and outside the `synex_core` Production-Beta certification boundary; its OneSync behavior and configuration are not part of the Core acceptance target.

The current snapshot creates bounded OneSync entities, maintains short-lived runtime mappings, persists only its own durable entity records, and owns the routing buckets it allocates. It does not claim deterministic client physics, permanent network ownership, or durable network IDs, and its interfaces may change during the rework.

Everything below is a source-level description of that snapshot, not installation or API guidance. Do not start `synex_entities`, apply its migration, or build a production integration against these interfaces before its rework receives separate acceptance.

## Historical snapshot assumptions

- The snapshot expects OneSync `on`, declares the `/onesync` manifest constraint, and repeats the check at runtime.
- Its manifest declares oxmysql `>=2.14.1 <3.0.0` and `synex_core` API `^1.0.0` dependencies.
- Its historical dependency order is oxmysql, Core, then entities; this is not a current start instruction.
- Its manifest lists `migrations/001_entities.sql`. The file contains one DDL statement and is marked non-transactional because MySQL/MariaDB DDL performs implicit commits; it is not part of the accepted Core schema.

The resource becomes unhealthy instead of registering its public contracts when OneSync, Core, or persistence is unavailable. `synex.entities.health@1.0.0` reports only the resource's actual state.

## Identity model

An entity reference is the pair `{ entityId, generation }`.

- `entityId` is allocated with the owner-bound `api.Ids.next('entity')` Core API. Callers cannot supply it.
- `entityId` is a stable Synex identifier. Its format is opaque and is not a cryptographic secrecy guarantee.
- `generation` changes when a durable record is rehydrated. A late reference to an older generation fails with `STALE_ENTITY`.
- `netId` is a current OneSync transport identifier. It is validated as a 16-bit value, reverse-indexed for the current runtime, and never persisted.
- `networkOwner` is an observed OneSync owner at read time. `-1` means the entity is currently orphaned. It never grants Synex authorization.
- `resourceOwner` is captured by Core from the invoking resource. That resource alone may resolve, move, or delete the registered entity.

FiveM network IDs are reusable and OneSync ownership can migrate when an entity leaves a player's scope. Durable code must therefore store the Synex ID, not the returned `netId`.

## Snapshot contract catalog

The following source example records how the snapshot called its local contract through `synex_core`. It is not an accepted integration example and may become invalid during rework.

```lua
local entity, entityError = exports.synex_core:Invoke(
    'synex.entities.spawn',
    '1.0.0',
    {
        entityType = 'vehicle',
        model = GetHashKey('blista'),
        vehicleType = 'automobile',
        position = { x = 2204.795, y = -887.9213, z = 1461.224 },
        heading = 90.0,
        bucket = 0,
        bucketGeneration = 0,
        persistent = false,
        owner = { type = 'resource', id = 'synex_example' },
    },
    {}
)

if not entity then
    print(entityError.code, entityError.message)
end
```

Every caller must declare the matching capability in its own `synex.resource.json` and receive an explicit Core policy grant. The default is deny.

| Contract | Capability | Purpose |
| --- | --- | --- |
| `synex.entities.spawn@1.0.0` | `synex.entities.spawn` | Create one validated server-side entity. |
| `synex.entities.get@1.0.0` | `synex.entities.read` | Revalidate and read a current entity reference. |
| `synex.entities.resolve_persistent@1.0.0` | `synex.entities.read` | Reacquire and lifecycle-claim the current generation and NetID by an owner-scoped persistent key. |
| `synex.entities.delete@1.0.0` | `synex.entities.delete` | Delete an owned runtime entity and finalize its durable row when applicable. |
| `synex.entities.bucket.create@1.0.0` | `synex.entities.bucket.create` | Allocate an owner-bound strict routing bucket. |
| `synex.entities.bucket.destroy@1.0.0` | `synex.entities.bucket.destroy` | Return players and durable entities to bucket `0`, and delete temporary entities. |
| `synex.entities.bucket.move_entity@1.0.0` | `synex.entities.bucket.entity.move` | Move an owned entity to bucket `0` or another bucket owned by the caller. |
| `synex.entities.bucket.move_player@1.0.0` | `synex.entities.bucket.player.move` | Move a connected source between bucket `0` and buckets owned by the caller. |
| `synex.entities.health@1.0.0` | `synex.entities.read` | Return bounded entity, bucket, OneSync, persistence, and service health. |

The service registry advertises `synex.entities@1` with read-only `getHealth` and `getControlSummary` methods. `getHealth` requires `synex.entities.health`; the bounded operational summary requires `synex.entities.read` and is used by the optional control plane and console diagnostics. State-changing consumers use the versioned contracts above so Core performs capability and schema validation and supplies the real invoking resource.

## Spawn policy

The only creation paths are:

- vehicles: `CreateVehicleServerSetter` with `automobile`, `bike`, `boat`, `heli`, `plane`, `submarine`, or `trailer`;
- peds: server-side `CreatePed` with ped types `0` through `29`;
- objects: `CreateObjectNoOffset` with an explicit door flag.

Requests reject unknown keys, non-finite or out-of-range numbers, invalid hashes, unsupported type-specific fields, unmanaged buckets, stale bucket generations, and foreign ownership. After creation the resource rechecks existence, entity type, normalized model hash, routing bucket, and NetID before returning the reference. Later reads repeat those checks and report `STALE_ENTITY` on divergence.

Server-setter creation waits at most 2.5 seconds for existence, a single delete waits at most one second, and an explicit bucket cleanup stops after a five-second temporary-entity deadline. Database driver timeouts remain controlled by oxmysql and the database connection settings.

Persistent keys use a bounded lowercase identifier format and are unique in memory and in `synex_entities`. Deleted rows retain their key as a tombstone, so a key is never silently rebound to another Synex ID. The database unique key is the final race guard. Runtime handles and NetIDs are deliberately absent from the table. SQL is private to this resource and always uses positional parameters through the locally injected oxmysql port; there is no public query or statement contract.

## Routing bucket policy

Managed buckets use `strict` entity lockdown and disable ambient population. Buckets are owner-bound and paired with an opaque Core-allocated generation token, so a reused numeric bucket ID cannot satisfy an old request even across resource restarts. A resource cannot move an entity or player into another resource's managed bucket, take over a player already tracked by another owner, or pull a player out of an unmanaged non-default bucket.

Routing buckets are dimensions for sessions and isolated game modes. They are not an interior system. Bucket `0` remains the unmanaged default and must use generation `0`.

| ConVar | Default | Hard ceiling | Meaning |
| --- | ---: | ---: | --- |
| `synex_entities_rehydrate_limit` | `512` | `5000` | Durable rows considered during one startup. |
| `synex_entities_drift_interval_ms` | `60000` | `3600000` | Delay between bounded runtime/persistence drift scans; minimum `10000`. |
| `synex_entities_drift_scan_limit` | `512` | `5000` | Durable rows considered per drift page; minimum `16`. |
| `synex_entities_bucket_min` | `1000` | `2147483647` | First managed bucket ID. |
| `synex_entities_bucket_max` | `999999` | `2147483647` | Last managed bucket ID. |
| `synex_entities_max_entities` | `4096` | `20000` | Total live registry entries. |
| `synex_entities_max_owner_entities` | `1024` | total limit | Live entries owned by one resource. |
| `synex_entities_max_buckets` | `1024` | `10000` | Total managed buckets. |
| `synex_entities_max_owner_buckets` | `128` | total limit | Buckets owned by one resource. |
| `synex_entities_max_bucket_entities` | `512` | total limit | Entities in one managed bucket. |
| `synex_entities_max_bucket_players` | `256` | `2048` | Players in one managed bucket. |

Changes to these ConVars take effect on resource start. The bucket range must be planned so it does not overlap another routing-bucket owner.

`synex_entities` deliberately does not change global server policy. Its `strict` lockdown applies only to buckets it owns. Operators should separately review the current Cfx.re behavior of `sv_entityLockdown` and `sv_filterRequestControl` against every installed resource; a global strict setting can break resources that legitimately depend on client-created entities. Do not copy a filter level without compatibility testing.

## Lifecycle and recovery

- On player drop, the source-to-bucket membership is removed.
- When an owning resource stops, its temporary entities receive a synchronous best-effort delete without waiting in the stop callback. Managed players are returned to bucket `0`; durable entities are moved to bucket `0` when the native accepts the move, use orphan mode `2`, and are marked `orphaned` asynchronously. A native cleanup failure is retained as degraded health instead of being reported as success.
- A stop that arrives during a yielding owner mutation advances the owner's lifecycle immediately but defers cleanup until that old mutation returns. Calls from a fast restart remain locked out during that interval, preventing cleanup from overtaking a durable insert.
- When `synex_entities` stops, focus is on synchronous cleanup: players return to bucket `0`, bucket policies are reset, and known runtime entities receive a best-effort delete. Durable rows remain.
- On the next start, rows in `active` or `orphaned` state are recreated in bucket `0` with a higher generation. Rows left in `deleting` state are finalized before rehydration.
- An owner that restarts uses `resolve_persistent` with its stable persistent key to claim the record for its current lifecycle and obtain the current generation and NetID. The claim changes only internal persistence status and remains restricted to the original resource owner.
- A scheduled bounded drift detector pages through durable records, compares them with current runtime ownership/existence, marks confirmed orphaned rows in batches, emits a bounded audit event on anomalies, and degrades resource health until a later consistent scan.

Orphan mode `2` prevents server relevancy cleanup; official Cfx documentation explicitly notes that a client can still request deletion. Entity creation and deletion are bounded and verified, but neither server setters nor ownership checks guarantee deterministic physics or permanent client execution.

Persistence stores the validated spawn descriptor, not live physics state. Rehydration therefore uses the original position and heading and always starts in bucket `0`. The current implementation assumes one active `synex_entities` runtime owns a database dataset; it does not provide a cross-server entity lease.

## Platform references

- [Cfx.re OneSync documentation](https://docs.fivem.net/docs/scripting-reference/onesync/)
- [Cfx.re routing bucket guidance](https://cookbook.fivem.net/2020/11/27/routing-buckets-split-game-state/)
- [Cfx.re security guidance for network events](https://docs.fivem.net/docs/developers/server-security/)
- [Cfx.re server commands and security ConVars](https://docs.fivem.net/docs/server-manual/server-commands/)
