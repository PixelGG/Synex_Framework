# Entity persistence

Entity persistence stores technical Entity definitions and authority metadata. It does not store vehicle fuel, registration, inventory, job state, interaction actions or physics snapshots.

## Owned schema

Four forward-only migrations own eight tables:

| Migration | Scope |
| --- | --- |
| `001_entities` | Base Entity definition and tombstone |
| `002_entity_lifecycle_authority` | Policies, lifecycle, provenance, archetype descriptor and recovery state |
| `003_entity_extensions` | Bindings, components, states, tags and checkpoints |
| `004_entity_cluster_recovery` | Authority leases and bounded recovery history |

```text
synex_entities
synex_entity_bindings
synex_entity_components
synex_entity_states
synex_entity_tags
synex_entity_checkpoints
synex_entity_authority_leases
synex_entity_recovery_history
```

Migration `001_entities.sql` remains unchanged. Later schema work is additive and forward-only. Applied checksums must never be rewritten.

## Persistence policies

| Policy | Durable key | Lifecycle intent |
| --- | --- | --- |
| `temporary` | none | Runtime-only; removed with the controlling resource |
| `session` | none | Bounded to the relevant session/scope lifecycle |
| `owner_lifetime` | required | Durable while the logical owner exists |
| `persistent` | required | Durable until explicit transfer/delete policy resolves it |

`automatic` recovery is accepted only for durable `persistent` or `owner_lifetime` definitions. Recovery policy is otherwise independent from persistence policy.

## Persistent keys and tombstones

Durable keys are lowercase and unique by `(resource_owner, persistent_key)`. Two resources may therefore use the same local key, while the same resource cannot create two definitions for it.

Deletion retains the Entity row as a tombstone. The unique key remains attached to that definition, so an old external reference cannot silently resolve to an unrelated new Entity.

## Checkpoints

`synex.entities.checkpoint` is explicit, caller-owned and generation-fenced. It records:

- observed position and heading;
- current bucket ID;
- a bounded generic spawn-state document;
- Entity generation, source resource, reason code, trace ID and version.

The server observes runtime position and heading; a caller does not submit arbitrary coordinates through the checkpoint contract. Per-Entity debounce and the contract rate limit bound writes. Checkpoints do not capture velocity, animations, wheel rotation, door angles or full gameplay state.

## Database boundary

Entity repositories use the caller-bound Core DataPort and parameterized positional queries. Public contracts expose no SQL, table name or transaction callback. Durable mutations use transactions, row locks, optimistic versions and the current Entity authority lease as appropriate.

Database time controls authority expiry, recovery due time and retention. Host clock time is not used to decide lease validity.

## Runtime-only data

Game handles, NetIDs, current network owners, resource-cycle-local callbacks and spatial-index cells are intentionally not durable. They are rebuilt or revalidated for each materialization.

## Acceptance boundary

The schema and repository paths have static/headless regression coverage. The four-migration chain still needs a fresh disposable MariaDB application, metadata inspection, concurrency cases and restored-upgrade rehearsal for the exact Entity candidate. Until then this document is a source model, not an accepted deployment procedure.
