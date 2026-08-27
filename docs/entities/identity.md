# Entity identity

Synex deliberately separates durable identity from FiveM runtime identity.

```text
Entity ID       ENT-...       stable definition identity
Generation      42            current materialization incarnation
Network ID      19284         transient OneSync transport identity
Game handle     29301         process-local runtime handle
```

## EntityRef

Stable APIs use an `EntityRef`:

```lua
{
    entityId = 'ENT-01K...',
    generation = 42,
}
```

The Entity ID identifies one definition. The generation identifies one runtime incarnation of that definition. Materialization claims increment the persisted generation before a FiveM Entity is activated. If the definition later materializes as generation `43`, a request carrying generation `42` fails with `STALE_ENTITY`.

The generation fence protects cached handles, interaction contexts, bucket moves, checkpoints, component/state writes and delete requests. A consumer should discard every cached runtime view when the generation changes.

## NetID and handle safety

NetIDs and handles are stored only in the runtime registry. They are not durable columns in `synex_entities` and must never be used as a vehicle, inventory, container or domain-record identity.

The runtime inspection path checks all of the following before returning a mapping:

- the handle still exists;
- the native Entity type matches the registered `vehicle`, `ped` or `object` type;
- the normalized model hash matches;
- the routing bucket matches;
- the current NetID matches;
- the observed network owner is a bounded integer.

If a NetID is reused, the old reverse mapping is inspected. A still-live collision is rejected; a stale mapping is detached and the new Entity keeps its own Entity ID and generation. NetID equality never makes two incarnations the same Entity.

## Lookup surfaces

The runtime registry maintains bounded indexes for:

- Entity ID;
- NetID;
- game handle;
- resource owner;
- logical owner;
- persistent key plus resource owner;
- active domain binding;
- routing bucket;
- bucket-local spatial cells.

`synex.entities.query.by_net_id` is an exact lookup for the current runtime mapping. It is useful for observation and operator search, not durable storage. Owner/resource/bucket queries page over durable definitions and merge current runtime data where available. Nearby queries use the bucket-isolated spatial index rather than scanning the whole world.

## Supported and excluded identities

Managed Entity types are limited to actual networked vehicles, non-player peds and objects. Player peds remain part of Core/player lifecycle. Zones, MLOs, door definitions, interactions and inventories are separate domain identities and do not become Entities merely because they can reference a position.

## Consumer rule

Persist a domain ID, an Entity binding or an Entity ID as appropriate. Persisting a NetID or game handle is always incorrect. When acting on a materialized Entity, require the complete current `EntityRef` and treat `STALE_ENTITY` as a normal concurrency result rather than retrying with an old generation.
