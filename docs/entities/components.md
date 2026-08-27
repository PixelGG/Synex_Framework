# Entity components

Components attach bounded, resource-owned extension data to a managed Entity. They are intentionally a small extension layer, not an entity-component-system scheduler.

Examples include a smart-object descriptor, world anchor or vehicle runtime projection. The domain resource remains responsible for the meaning and behavior of that data.

## Schema registration

Before writing a component, its owner resource registers a schema through `synex.entities.component.schema.register`. A definition includes:

- namespaced component name;
- positive schema version;
- persistence mode;
- maximum public encoded schema/payload bytes (`1..16384`, matching the Core contract string limit);
- maximum value depth (`1..16`);
- bounded JSON schema;
- resource-owned reason code.

The registry is tied to the current Core owner epoch. A new resource epoch replaces the previous registrations, and stale callbacks cannot register or mutate against the new epoch. Namespaces must belong to the registering resource.

Schema definitions reject unknown schema keywords, excessive depth/nodes, mixed or sparse arrays, cycles, non-finite numbers, metatables and unsupported values. Payload JSON is decoded, validated, canonicalized and size-checked before storage.

## Persistence modes

| Mode | Runtime memory | Entity database | State-bag projection |
| --- | --- | --- | --- |
| `runtime` | Yes | No | No |
| `persistent` | No | Yes | No |
| `replicated` | No | Yes | Yes, under `synex:component:<namespace>` |

Runtime components are generation-bound and removed on dematerialization, deletion, unexpected removal, NetID-reuse detach and owner-resource cleanup. Persistent and replicated rows remain attached to the durable Entity definition until explicitly removed or the Entity definition is terminated.

Replicated components are revalidated against the currently registered schema before materialization hydration. Missing or mismatched registrations fail the hydration path instead of projecting unvalidated data.

## Ownership and concurrency

A resource may mutate only a component schema it owns. `component.set` and `component.remove` require:

- a current resource-owned `EntityRef`;
- the registered schema and exact schema version;
- current authority lease for durable modes;
- expected component version;
- reason code and idempotency key;
- the appropriate write capability.

Reads remain capability-gated. They do not transfer ownership. The durable primary key is `(entity_id, component_namespace)`, and owner/schema/mode/version checks are repeated inside the database mutation.

## Versioning guidance

Schema versions are immutable identities for compatibility, not mutable labels. Change the version when the accepted payload shape changes. A persistent Entity can retain an older frozen archetype reference; the owning resource must deliberately provide the compatible schema before hydration or migrate its domain data through a reviewed forward-only path.

Do not use components as an unbounded metadata dump. Prefer one focused namespace per independent domain contract, small canonical payloads and separate state keys for frequently changing replicated values.
