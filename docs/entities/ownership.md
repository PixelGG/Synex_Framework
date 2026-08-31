# Ownership model

`synex_entities` keeps distinct concepts that must not be collapsed into a single `owner` field.

| Concept | Meaning | Authorization effect |
| --- | --- | --- |
| Logical owner | Domain subject associated with the Entity | Domain fact; validated but not sufficient by itself |
| Resource owner | Server resource controlling technical lifecycle | Primary mutation boundary |
| Runtime authority | FXServer instance holding the durable lease | Fences persistent materialization and mutation |
| Network owner | Client observed by OneSync transport | None |
| Current user | Player currently interacting with the Entity | Evaluated by a consuming domain; not Entity ownership |

## Logical owner

Supported logical owner types are:

- `character`;
- `group`;
- `resource`;
- `system`;
- `user`.

Character ownership is checked through the Core Character API and rejects missing, deleted or inactive characters. Group ownership is checked through the optional `synex.groups@1` service and fails closed when the group service cannot establish the owner. A `resource` logical owner must equal the immediate invoking resource. All owner identifiers are bounded and validated.

`synex.entities.owner.set` changes only the logical owner. It requires the current `EntityRef`, expected durable version, reason code, idempotency key, capability and resource ownership. The transition runs a pre-operation hook and is recorded through event/audit paths.

## Resource owner

The resource owner is captured from Core caller context, never accepted as request data. It owns:

- Entity lifecycle mutations;
- active bindings and persistent keys;
- archetype/schema namespaces;
- managed buckets and their assignments;
- cleanup responsibility on resource stop.

The resource epoch is part of this boundary. Old callbacks from a previous restart receive `STALE_RESOURCE` or fail the owner-epoch fence. The current public surface intentionally provides no blind takeover or resource-owner handoff.

## Runtime authority

Every durable materialization uses an authority lease containing server scope, instance ID, resource epoch, opaque token, lease generation and database-time expiry. The lease answers which server instance may control the persistent Entity; it does not change logical ownership.

See [Cluster authority](cluster-authority.md).

## Network owner

The Cfx network owner is an observed synchronization/transport value. It can change as OneSync migrates control and is returned only as runtime information. It never grants a Core capability, binding ownership, bucket ownership, state authority or permission to delete/move the Entity.

Every operator surface must label it as transport-only.

## Current user and interactions

Entities does not store a generic current-user lease. `synex.entities.context.validate` can verify an active source, current generation, existence, same bucket, server-observed distance and required owner/tags/components for a consuming server resource. A gameplay interaction lease belongs to `synex_interact`, not to the Entity authority lease system.
