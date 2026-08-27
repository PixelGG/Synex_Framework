# Custom group types, attributes, and definitions

> [!NOTE]
> This page documents the current Experimental Alpha. See [Organizations Engine status](overview.md#maturity-and-acceptance) before deploying it.

Group types and schemas are extension points. They classify organizations and define bounded domain defaults without embedding an owner's gameplay code in `synex_groups`.

## Owner-bound group types

Before registering any extension definition, its owner must call `synex.groups.registries.begin` for the current resource start. The same start-scoped idempotency key is reused for begin retries; a restart uses a new key. Beginning creates an active owner-epoch synchronization session, advances its generation, and disables the owner's previously active group types, relation types, duty states, and attribute schemas so that omissions are removed deliberately. Call begin even when the new desired set is empty.

`synex.groups.types.register` accepts a lowercase type key, label, monotonically advancing `schema_version`, and optional bounded policy fields:

- dynamic creation, creator permission, approval quorum, and approver permission;
- total and active membership limits;
- default grades and roles;
- allowed membership and duty states;
- metadata, including a closed application schema.

The real Core caller becomes the stored owner; an input field cannot impersonate another resource. Only that owner may update the type. Each registration requires the caller's exact active synchronization session. Persisted owner epochs fence stale restart-scoped registrations, and the in-memory registries are bounded globally and per owner. Registry state is hydrated only from persisted active registrations whose owner epoch matches an active synchronization session. Resource-stop cleanup deactivates and removes the exact stopped epoch without touching a newer restart.

A custom type creates domain classification and policy context only. It does not create UI, payroll, inventory, vehicles, interactions, notifications, or compatibility mappings.

### Application schema

Type metadata may contain a closed `application_schema`. It supports a bounded set of named properties of type `string`, `integer`, `number`, or `boolean`, a unique required-field list, scalar enums, string-length bounds, and numeric minimum/maximum bounds. Additional properties are rejected.

Application submission requires the request's `schema_version` to equal the current type version. Changing a form therefore requires a forward type version. See [Applications](approvals.md#membership-applications).

## Relation types and duty states

`synex.groups.relation_types.register` and `synex.groups.duty_states.register` use the same owner, owner-epoch, schema-version, persistence, and runtime-registry rules.

- A relation type declares `directed` or `symmetric` behavior.
- A duty state declares whether it counts as on duty.

Their labels and keys carry no gameplay effects. See [Relationships](relationships.md) and [Duty](duty.md).

## Attribute schemas

`synex.groups.attributes.register_schema` registers an owner-bound schema for one namespace/key. A schema may be global or scoped to one `group_type`. An active type-specific schema overrides the global schema with the same namespace/key; even a disabled scoped record blocks silent fallback to that global definition.

Supported value types are:

- `string`;
- `integer`;
- `decimal`;
- `boolean`;
- `datetime`;
- bounded `json`.

The closed validation object supports `required`, string `min_length`/`max_length`, numeric `minimum`/`maximum`, and bounded scalar `enum` values where applicable. The top-level `required` field and validation declaration must agree. A required schema must declare a type-valid deterministic `default`.

### Visibility

| Visibility | Read boundary |
| --- | --- |
| `public` | Any server caller that passed the contract capability |
| `members` | Active member of the target group |
| `management` | Actor with `synex.groups.attributes.read` inside the group |
| `staff` | Actor with Core character permission `synex.groups.attributes.staff.read` |
| `hidden` | Subject character or current schema-owner epoch |
| `server_only` | Current schema-owner resource and epoch only |
| `private` | Subject character only |

`attributes.get` requires the caller-resource capability `synex.groups.attributes.read`. `attributes.set` requires caller-resource and actor `synex.groups.attributes.manage` authority. An optional schema capability is an additional character-authorization gate. `server_only` writes also require the current schema owner epoch.

`synex.groups.attributes.set` validates the active effective schema and typed value. Updating an existing value requires `expected_version`. `synex.groups.attributes.get` returns one explicit visible value; attributes are never folded into membership directory results.

For a missing value, hidden schema, denied visibility, or denied schema-specific capability, `attributes.get` returns the same `ATTRIBUTE_NOT_FOUND` shape. This concealment prevents a caller from using error differences to enumerate private attributes. Retryable Core or database failures remain generic retryable infrastructure errors rather than being disguised as absence.

When a membership becomes active through creation, invitation, application approval, or a lifecycle transition, the same transaction resolves the effective schema set, validates existing values, materializes defaults, and fails closed if a required value cannot be satisfied. History effects record value presence, not private values.

Attributes are not a storage shortcut for balances, inventory, permissions, vehicles, or large gameplay documents.

## Static definition synchronization

`synex.groups.definitions.sync` is the owner-controlled boundary for complete static definition sets. The request contains an owner schema version, a bounded set of unique definitions, and `dry_run`. If `owner_resource` is provided, it must equal the real caller.

Current kinds are `group`, `group_type`, `relation_type`, `attribute_schema`, and `duty_state`. The request is bounded to 16 top-level definitions and a fixed reconciliation work budget; each definition is copied as plain bounded JSON, canonically encoded, and SHA-256 digested by MariaDB.

### Live group materialization

`kind: group` has an implemented materializer. A group definition owns:

- live organization identity/profile and optional parent from the same owner set;
- at least one grade and optional roles;
- supported group-, grade-, and role-capability rules;
- static provenance and the applied definition digest.

Parent definitions are topologically ordered. New definitions create the live group model; unchanged definitions verify it without rewriting versions; safe updates reconcile it transactionally.

The other supported kinds are persisted catalog definitions. They do **not** replace the dedicated owner-bound registration contracts for live group types, relation types, duty states, or attribute schemas.

### Drift and reconciliation

Dry-run produces a bounded plan without mutating definition or runtime state. A non-dry sync:

- creates, updates, restores, or verifies the owner's desired definitions;
- requires a forward `schema_version` for changed content;
- records applied definition migrations and snapshots;
- marks previously owned definitions omitted from the complete request as blocked;
- records issues and leaves the live model unchanged when reconciliation would be unsafe.

For example, removing a grade with active holders records drift and a blocked migration instead of partially deleting it. After the blocking references are resolved through ordinary public operations, resubmitting the same desired revision can finalize that recorded migration. There is no arbitrary bulk SQL migration hook.

Use this supported multi-revision sequence when renaming, replacing, or removing an applied grade:

1. Publish revision N with both the old grade and its target replacement, dry-run it, then apply it.
2. Enumerate the affected memberships through the authorized bounded read API. For each membership, call `synex.groups.members.set_grade` with its current `expected_version`, a workflow-stable `idempotency_key`, and an explicit migration reason. Resolve `CONCURRENT_MODIFICATION` by rereading and deciding again; do not bypass authority or write the tables directly.
3. Verify that no non-terminal membership, live invitation, or pending grade-change proposal still references the old grade and that Groups Doctor has no related failure. Terminal membership history may retain the old identity.
4. Publish revision N+1 without the old grade, dry-run it, and apply it. If an actionable reference remains, synchronization records blocked drift and leaves the live definition intact. Once reference-free, the same desired revision CAS-retires the grade and its controls as `disabled` without deleting historical identity. Replaying that revision is a no-op; a later definition may re-add the key by reactivating the same public grade identity.

This orchestrated public-API path is the structural migration mechanism. `definitions.sync` does not accept a bulk mapping DSL or arbitrary migration code.

`synex.groups.doctor` reports definition drift and unresolved issues but never repairs them automatically.

## Resource author checklist

1. Choose globally distinct lowercase type and namespace keys.
2. Declare consumed contracts/services and exact Core resource capabilities.
3. Call `synex.groups.registries.begin` once per resource start, then register the complete desired registry set for that exact epoch.
4. Register and reconcile definitions only from server code; the sole client contract is the read-only, session-bound `synex.groups.self.snapshot` and cannot register definitions.
5. Use stable schema versions, a start-scoped begin key, and workflow-derived operation idempotency keys.
6. Run `definitions.sync` with `dry_run = true` first.
7. Review drift, issues, and Doctor output before applying a changed definition.
8. Never mutate Groups-owned tables or reuse another resource's owner identity.
