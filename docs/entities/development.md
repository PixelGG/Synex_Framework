# Developing with Entity Authority

This page describes the current Experimental Alpha server-to-server boundary. Contract names, schemas and capabilities remain experimental until an exact candidate is promoted.

## Consume through Core

A consumer declares the exact Entity contracts it uses in its Synex resource descriptor, requests the matching capabilities and receives an explicit operator policy grant. It then invokes the contract from server Lua through Core:

```lua
local result, invokeError = exports.synex_core:Invoke(
    'synex.entities.get',
    '^1.0.0',
    {
        entityId = entityRef.entityId,
        generation = entityRef.generation,
    }
)

if invokeError then
    if invokeError.code == 'STALE_ENTITY' then
        -- Discard the cached runtime reference and resolve domain state again.
        return
    end
    error(invokeError.message)
end
```

The second return slot is authoritative for failure. Do not wrap this call in a convenience export that would hide the original resource caller from Core.

## Recommended integration order

1. Keep the domain record in its owning resource.
2. Register component/state schemas needed by the resource epoch.
3. Register an archetype for the intended Entity type and allowed models.
4. Use a stable domain binding when one domain record must have at most one active Entity.
5. Spawn or materialize from the server with a logical owner, reason code and idempotency key.
6. Store the returned Entity ID/binding in domain state; cache the generation only for current runtime work.
7. Use explicit checkpoint/dematerialize/delete operations for lifecycle transitions.
8. Treat `STALE_ENTITY`, `STALE_BUCKET`, `CONCURRENT_MODIFICATION` and lease conflicts as expected concurrency outcomes.

Raw spawn is a privileged fallback. Official resources should prefer registered archetypes so model/type/default/schema intent is explicit and restart-compatible.

## Domain separation

Good:

```text
synex_vehicles owns VIN, plate, mods, fuel and registration
synex_entities owns EntityRef, materialization, NetID mapping and authority
```

Bad:

```text
store a NetID as the vehicle ID
write fuel or inventory into the Entity definition
infer permission from the Cfx network owner
delete or move the native Entity behind synex_entities
```

## Interaction preparation

`synex.entities.context.validate` can validate current generation, materialization, player/source activity, same bucket, server-observed distance and required logical owner/tags/components. It is a primitive for a later interaction domain, not a user lease, intent engine or authorization decision by itself.

## Idempotency and errors

Mutation contracts that require an idempotency key bind it to their operation/request through Core. Reuse the same key only for an exact retry. Do not retry validation, ownership or stale-reference failures blindly.

Structured public errors include Entity/bucket not-found and stale outcomes, binding/materialization conflicts, invalid type/model/position/owner/schema data, quota/rate limits, spawn/delete failures, authority conflict and concurrent modification. Recovery pause/failure codes remain internal worker/diagnostic state unless a contract explicitly declares a compatible public outcome. Use the canonical generated catalog for the exact set per contract.

Every contract response passes through the Entity public-error boundary before Core returns it to the consumer. That boundary restricts the code to the exact generated error set for the invoked contract/version, maps database, persistence, capability and idempotency internals to a compatible public code, removes provider trace IDs, and preserves only bounded quota scope/limit details. Core supplies the caller-visible trace ID. Native handles, SQL, driver messages and internal authority tokens are never part of the public error contract.

## Verification

Run only repository-defined gates:

```bash
node tools/test-runner.mjs entities
npm run generate:check
npm run check
npm test
npm run security
```

The Entity benchmark measures real local Lua lookup/validation paths through deterministic adapters. It is not an FXServer, OneSync or MariaDB performance claim. Live acceptance must use a disposable schema, the exact candidate and the matrix in [Testing](../testing.md).

## References

- [Entity overview](overview.md)
- [Contract and configuration reference](../reference/entities.md)
- [Create a Synex resource](../development/creating-resources.md)
- [Generated contracts](../../packages/contracts/generated/docs/contracts.md)
- [Security](security.md)
