# Domain bindings

A binding connects one managed Entity definition to one record owned by another Synex domain without moving that domain data into `synex_entities`.

```text
synex_vehicles vehicle VEH-123
             |
             | binding namespace/ref
             v
synex_entities Entity ENT-9182 generation 4
```

Example shape:

```lua
{
    namespace = 'synex_vehicles.vehicle',
    ref = 'VEH-123',
}
```

## Invariants

- At most one active Entity can hold a given `(binding_namespace, binding_ref)`.
- At most one active binding can point to one Entity.
- The binding row records the owning server resource.
- Released bindings remain in history with a reason code and timestamp.
- Binding lookup returns a definition only when the binding is still active.

The uniqueness constraints are database-backed, not only in-memory checks. The spawn path also serializes a binding lane, reserves the binding before native creation and maps a racing contender to `BINDING_CONFLICT` or `ENTITY_ALREADY_MATERIALIZED` rather than creating two active runtime Entities.

## Resource ownership

The immediate Core caller becomes the binding `owner_resource`. `synex.entities.binding.get` returns a binding only to that resource owner. A binding does not grant another resource permission to mutate the Entity, and it does not transfer the Entity's `resourceOwner`.

The current public API has no resource-owner handoff contract. Logical ownership can change through `synex.entities.owner.set`, but technical lifecycle authority remains with the original resource. Cross-resource handoff must not be emulated by changing database rows or reusing another resource's binding.

## Persistent keys are different

A persistent key is local technical identity within the resource namespace. A domain binding identifies an external domain object. A resource may use both, but they solve different problems:

| Mechanism | Identity scope | Primary use |
| --- | --- | --- |
| Persistent key | `(resourceOwner, persistentKey)` | Resolve one durable Entity definition owned by that resource |
| Binding | `(namespace, ref)` | Enforce one active Entity for one external domain record |

Neither should be replaced with a NetID.

## Consumer guidance

Use a binding when a durable domain object may be materialized, dematerialized and materialized again. Keep the domain record authoritative for its own facts. Resolve or materialize through the Entity contract, then cache only the returned current `EntityRef` for runtime operations.
