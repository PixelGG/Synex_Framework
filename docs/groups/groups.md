# Groups and group types

> [!NOTE]
> This page documents the current Experimental Alpha. See [Organizations Engine status](overview.md#maturity-and-acceptance) before deploying it.

A group is a durable organization entity. A police department, hospital, company, gang, family, club, crew, agency, or department is a classification and extension of that entity, not a separate authorization system.

## Identity

Every group has:

- an opaque public ID allocated through Core;
- a bounded, unique lowercase slug;
- a registered group type;
- a name, label, optional description, visibility, and bounded metadata;
- lifecycle/status projections and optimistic versions;
- optional parentage in the organization hierarchy;
- static or dynamic creation provenance.

Consumers persist public IDs, not internal numeric keys. IDs are opaque and must not be parsed for authority or type. Slugs use the lowercase `^[a-z][a-z0-9_-]*$` contract shape and are protected by a transactional reservation table.

## Group types

The migrations seed these neutral type keys:

`job`, `government`, `law_enforcement`, `medical`, `gang`, `business`, `organization`, `faction`, `department`, `club`, `family`, `crew`, and `custom`.

They do not implement matching gameplay. `law_enforcement`, for example, does not provide police actions, vehicles, payroll, evidence, or an MDT.

After the owner starts its current complete-set synchronization with `synex.groups.registries.begin`, `synex.groups.types.register` is owner-bound and versioned. A type can define:

- dynamic-creation availability and a type-specific Core character permission;
- zero or more independent approvals plus the approval permission;
- total and active membership limits;
- default grades and roles for dynamically created groups;
- allowed membership and duty states;
- bounded metadata, including a closed application schema.

Hierarchy and relationship availability are persisted in the type model. The current owner-registration contract creates both as enabled and does not expose those two flags for caller configuration.

Only the owning resource may change its registered type, and a changed definition must advance `schema_version`. See [Custom group types](custom-group-types.md).

## Dynamic creation

`synex.groups.create` creates only dynamic organizations. The actor must hold the type's configured Core character permission.

- With `required_approvals = 0`, the command creates the organization immediately.
- With a positive quorum, the same command records a 48-hour creation request instead. Authorized characters decide it through the creation-request contracts. The creator cannot decide their own request.

At execution, the system revalidates the creator and approver permissions, type identity and version, approved request body, hierarchy, capacity, and slug ownership. Creation then atomically materializes the group, hierarchy closure, reserved Owner grade, configured default grades and roles, founding active membership, primary projection, required attribute defaults, capability bootstrap, history, and outbox effects.

### Slug reservations

The slug reservation is the serialization point shared by direct creation, approval-backed creation, and slug updates. A pending or approved creation request therefore races safely with direct creation on another connection.

- rejection and expiry release a creation request's reservation;
- successful approval execution transfers it to the new group;
- a slug update reserves the new slug before releasing the old one;
- archive and coordinated deletion retain the group-owned reservation, so a deleted identity is not silently reused.

## Static organizations

Passing `dynamic = false` to `synex.groups.create` fails closed. Static organizations are owned and reconciled through `synex.groups.definitions.sync`.

An applied `group` definition materializes and maintains the live organization profile, hierarchy, grades, roles, and supported capability rules. Unsafe drift, such as removing a grade that still has active holders, records an issue and blocks that definition migration without partially rewriting the live model. See [Static definition synchronization](custom-group-types.md#static-definition-synchronization).

## Hierarchy

A group may have one direct parent when its type permits hierarchy. Direct edges and a closure projection support bounded ancestor and subtree queries. Parent changes:

- reject self-parenting and indirect cycles;
- require an active parent;
- enforce the depth bound of 64;
- rebuild affected closure paths transactionally;
- advance the group and read-model versions.

Hierarchy is containment. Alliances, hostility, partnerships, affiliation, and subsidiary edges use [relationship entities](relationships.md).

```text
Organization
|-- Division
|   `-- Team
`-- Independent unit
```

The example expresses structure only; no gameplay behavior is implied.

## Archive and coordinated deletion

Archive is a soft deactivation operation. It is rejected while any of these remains: an active child; a membership outside `TERMINATED`, `LEFT`, or `ARCHIVED`; a non-ended relationship; or an open assignment, invitation, application, or proposal. Archival keeps membership, history, audit, closed workflows, and slug identity durable.

`synex.groups.delete` is available only for a stable archived organization, requires optimistic group versioning, a reason, the caller-resource capability, and the actor's Core character permission `synex.groups.delete`. It creates a durable deletion request rather than deleting rows inline.

The Groups deletion worker submits that request to Core's domain-deletion coordinator. Registered providers may retain, perform bounded cleanup, or block the plan. Groups itself always retains its soft-deleted domain history. A successful plan advances the organization through `ARCHIVED -> DISSOLVING -> DELETED`; blocked and failed plans remain observable and are reconciled after restart. This is coordinated soft deletion, not SQL row removal.

## Principal contracts

| Area | Contracts |
| --- | --- |
| Create and approvals | `synex.groups.create`, `synex.groups.creation_requests.get`, `.approve`, `.reject` |
| Read and update | `synex.groups.get`, `synex.groups.list`, `synex.groups.update` |
| Lifecycle | `synex.groups.archive`, `synex.groups.delete` |
| Type extension | `synex.groups.types.register` |

All are server-local and experimental. Use the [generated catalog](../../packages/contracts/generated/docs/contracts.md) for exact schemas and capabilities.
