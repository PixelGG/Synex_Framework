# `synex_groups` reference

> [!WARNING]
> `synex_groups` is an **Experimental Alpha Organizations Engine**. Its uncommitted working tree passed repository, disposable-MariaDB, isolated-FXServer, restart, and Doctor checks on 2026-08-25. The manual client self-projection smoke, exact committed-revision review, and explicit owner maturity/publication decision remain open. It remains excluded from the accepted `synex_core` Production-Beta profile and may still change contracts, schema, migrations, and behavior.

The Alpha is a server-authoritative, offline-first domain resource for groups, types, hierarchy, relationships, character memberships, grades, roles, capabilities, delegations, duty, assignments, applications, approvals, attributes, definitions, history, and diagnostics. One bounded client projection exposes only the active session's own organization view.

Detailed architecture and integration guidance starts at [Organizations Engine overview](../groups/overview.md).

## Runtime boundary

- Required runtime dependency: `synex_core` only. Database access is caller-bound through Core's ownership-checked `api.Database` DataPort; Groups has no direct oxmysql dependency.
- Resource criticality: `critical: false`. This discovery setting is not a maturity or production-readiness claim.
- Provided service: `synex.groups@1`.
- Public surface: 71 Groups contracts in the current 204-definition source catalog; these counts describe the current revision and are not an API invariant.
- Stability: every current contract is `experimental`.
- Transport: 70 Groups contracts are `network: none`; exactly `synex.groups.self.snapshot` is `client-to-server`. No standalone Groups NetEvent is registered.
- Persistence: Groups-owned relational tables, transactional idempotency/history/audit/outbox, and bounded expiry maintenance.
- Core binding: generation-fenced, resumable, and fail-closed until the complete registration barrier is ready.
- Excluded domains: accounts/payroll, inventory, vehicles, world state, interactions, notifications, gameplay, and NUI.

Core first authorizes the calling resource from its current manifest and operator policy. Actor-driven operations then evaluate the character's grade/role/delegation authority and any active exact Groups policy inside the target organization. Resource permission and character permission are separate requirements.

### Registration readiness

A Groups binding generation is ready only after its deletion provider, character-lifecycle participant, `synex.groups@1` service, all 71 RPC handlers, and five scheduler workers have registered. Until then, the service remains `UNHEALTHY`, and readiness guards keep public handlers and workers fail-closed.

Retryable registration attempts preserve a progress journal. Scheduler rollback and cancellation are token-aware, preventing an old attempt from removing a newer worker or creating duplicates. Exhausting retryable attempts starts another generation-fenced recovery cycle after five seconds; a non-retryable error is terminal for that generation. Core stop immediately fences the generation, current API reference, and readiness state before yielding cleanup.

Automated rebind regressions exercise interrupted registration and Core stop/start. Historical live evidence from the earlier working tree includes a Groups restart with owner-epoch advance and a Core restart with the expected dependency stop; `ensure synex_groups` restored both resources to `HEALTHY` and Doctor to `PASS`. The current 71-contract, 31-migration source includes later changes and does not inherit that result.

### Extension-registry owner session

`synex.groups.registries.begin` is mandatory once per extension-resource start before any group-type, relation-type, duty-state, or attribute-schema registration. Retry that begin with the same start-scoped `idempotency_key`; use a new key after restart. The call binds the real Core caller and current owner epoch, advances the persisted synchronization generation, and disables the owner's previously active definition set. Calling it with no subsequent registrations is the supported way to publish an empty set.

Each registration requires that exact active owner session. Hydration ignores persisted rows without a matching active session, and resource-stop cleanup deactivates only the observed stopped epoch before removing its runtime entries. These fences reject stale callbacks and prevent an older stop from deleting a newer restart's definitions.

## Contract catalog

The generated [contract catalog](../../packages/contracts/generated/docs/contracts.md) is authoritative for exact JSON Schemas, versions, idempotency flags, and declared error codes.

### Organizations and structure

| Contract | Resource capability | Mutation |
| --- | --- | --- |
| `synex.groups.create` | `synex.groups.create` | yes |
| `synex.groups.delete` | `synex.groups.delete` | yes |
| `synex.groups.creation_requests.get` | `synex.groups.creation_requests.read` | no |
| `synex.groups.creation_requests.approve` | `synex.groups.creation_requests.decide` | yes |
| `synex.groups.creation_requests.reject` | `synex.groups.creation_requests.decide` | yes |
| `synex.groups.get` | `synex.groups.read` | no |
| `synex.groups.list` | `synex.groups.read` | no |
| `synex.groups.update` | `synex.groups.update` | yes |
| `synex.groups.archive` | `synex.groups.archive` | yes |
| `synex.groups.registries.begin` | `synex.groups.registries.manage` | yes |
| `synex.groups.types.register` | `synex.groups.types.manage` | yes |
| `synex.groups.relation_types.register` | `synex.groups.types.manage` | yes |
| `synex.groups.duty_states.register` | `synex.groups.types.manage` | yes |
| `synex.groups.relationships.create` | `synex.groups.relationships.manage` | yes |
| `synex.groups.relationships.update` | `synex.groups.relationships.manage` | yes |
| `synex.groups.relationships.get` | `synex.groups.relationships.read` | no |
| `synex.groups.relationships.list` | `synex.groups.relationships.read` | no |

### Membership, grade, and role

| Contract | Resource capability | Mutation |
| --- | --- | --- |
| `synex.groups.members.get` | `synex.groups.members.read` | no |
| `synex.groups.members.list` | `synex.groups.members.read` | no |
| `synex.groups.members.invite` | `synex.groups.members.invite` | yes |
| `synex.groups.members.accept` | `synex.groups.members.accept` | yes |
| `synex.groups.members.decline` | `synex.groups.members.accept` | yes |
| `synex.groups.members.revoke_invite` | `synex.groups.members.invite` | yes |
| `synex.groups.members.transition` | `synex.groups.members.manage` | yes |
| `synex.groups.members.transition_policy.get` | `synex.groups.policies.manage` | no |
| `synex.groups.members.transition_policy.set` | `synex.groups.policies.manage` | yes |
| `synex.groups.members.set_grade` | `synex.groups.grades.manage` | yes |
| `synex.groups.members.set_visibility` | `synex.groups.members.manage` | yes |
| `synex.groups.members.set_primary` | `synex.groups.members.primary` | yes |
| `synex.groups.reporting.set` | `synex.groups.reporting.manage` | yes |
| `synex.groups.grades.create` | `synex.groups.grades.manage` | yes |
| `synex.groups.grades.update` | `synex.groups.grades.manage` | yes |
| `synex.groups.roles.create` | `synex.groups.roles.manage` | yes |
| `synex.groups.roles.update` | `synex.groups.roles.manage` | yes |
| `synex.groups.roles.assign` | `synex.groups.roles.manage` | yes |
| `synex.groups.roles.remove` | `synex.groups.roles.manage` | yes |

### Authority and policy

| Contract | Resource capability | Mutation |
| --- | --- | --- |
| `synex.groups.capabilities.set` | `synex.groups.capabilities.manage` | yes |
| `synex.groups.capabilities.check` | `synex.groups.read` | no |
| `synex.groups.capabilities.explain` | `synex.groups.read` | no |
| `synex.groups.delegations.create` | `synex.groups.delegations.manage` | yes |
| `synex.groups.delegations.revoke` | `synex.groups.delegations.manage` | yes |
| `synex.groups.policies.set` | `synex.groups.policies.manage` | yes |
| `synex.groups.policies.simulate` | `synex.groups.read` | no |

### Duty and assignments

| Contract | Resource capability | Mutation |
| --- | --- | --- |
| `synex.groups.duty.start` | `synex.groups.duty` | yes |
| `synex.groups.duty.update` | `synex.groups.duty` | yes |
| `synex.groups.duty.stop` | `synex.groups.duty` | yes |
| `synex.groups.duty.list` | `synex.groups.duty.read` | no |
| `synex.groups.assignments.get` | `synex.groups.assignments.read` | no |
| `synex.groups.assignments.list` | `synex.groups.assignments.read` | no |
| `synex.groups.assignments.create` | `synex.groups.assignments.manage` | yes |
| `synex.groups.assignments.join` | `synex.groups.assignments.manage` | yes |
| `synex.groups.assignments.leave` | `synex.groups.assignments.manage` | yes |
| `synex.groups.assignments.complete` | `synex.groups.assignments.manage` | yes |
| `synex.groups.assignments.cancel` | `synex.groups.assignments.manage` | yes |

### Applications and approvals

| Contract | Resource capability | Mutation |
| --- | --- | --- |
| `synex.groups.applications.submit` | `synex.groups.applications` | yes |
| `synex.groups.applications.review` | `synex.groups.applications.review` | yes |
| `synex.groups.applications.withdraw` | `synex.groups.applications` | yes |
| `synex.groups.proposals.create` | `synex.groups.approvals.manage` | yes |
| `synex.groups.proposals.approve` | `synex.groups.approvals.manage` | yes |
| `synex.groups.proposals.reject` | `synex.groups.approvals.manage` | yes |

There is no separate public execution contract. Reaching the threshold executes only one of the closed, server-side Groups actions documented under [Approvals](../groups/approvals.md#bounded-execution-map); arbitrary payload-selected handlers and cross-domain actions are not supported.

### Definitions, attributes, and diagnostics

| Contract | Resource capability | Mutation |
| --- | --- | --- |
| `synex.groups.attributes.get` | `synex.groups.attributes.read` | no |
| `synex.groups.attributes.register_schema` | `synex.groups.attributes.manage` | yes |
| `synex.groups.attributes.set` | `synex.groups.attributes.manage` | yes |
| `synex.groups.definitions.sync` | `synex.groups.definitions.manage` | yes |
| `synex.groups.directory.list` | `synex.groups.directory.read` | no |
| `synex.groups.history.list` | `synex.groups.history.read` | no |
| `synex.groups.compatibility.resolve_target` | `synex.groups.read` | no |
| `synex.groups.compatibility.set_primary_grade` | `synex.groups.compatibility.set_primary_grade` | yes |
| `synex.groups.doctor` | `synex.groups.read` | no |

The compatibility resolver accepts one affected `actor_character_id` plus exact native `group_type`, `group_key`, and `grade_key` values. It resolves only active type/group/grade records and returns public IDs plus optional membership, primary-selection, and active duty revisions. Its SQL reads are bounded and indexed; ambiguous, incomplete, inactive, or malformed durable state fails closed. It returns no internal database identifiers, labels, metadata, or other character data and grants no mutation authority.

`compatibility.set_primary_grade` is the atomic native boundary for a reviewed compatibility mapping. It requires the narrow caller capability shown above, the ordinary actor-domain `synex.groups.grades.manage` decision, an active self-owned membership, a sealed approved proposal, the expected membership version, and the expected primary revision (`0` means no primary row exists). Grade placement and primary selection commit in one Groups/DataPort transaction or roll back together. The resolver and mutation do not create memberships, bypass grade capacity/rank policy, or authorize a Bridge consumer by themselves. Duty changes continue through the native duty contracts.

### Client self projection

| Contract | Resource capability | Mutation |
| --- | --- | --- |
| `synex.groups.self.snapshot` | none; active Core session required | no |

`self.snapshot` is the only Groups client-to-server contract. Its closed request accepts only an optional cursor and a limit of at most 8. Each membership carries at most eight public roles and reports `roles_truncated` when more exist. Core validates the current `ACTIVE` session/source generation and applies a capacity-4, refill-1-per-second rate bucket; Groups derives the actor character from that session. The bounded response contains only the caller's own memberships, organization summaries, public grade/role data, and current duty state. A client cannot supply another character ID, enumerate members, read private attributes/history, or mutate organization state through this projection.

`directory.list` applies membership visibility server-side: public rows are visible to every authorized caller, member rows to active group members, management rows to active actors with `synex.groups.directory.manage` or `synex.groups.members.read`, hidden and legacy private rows only to the subject character, and server-only rows never through the directory. `members.set_visibility` is the actor-authorized, versioned mutation for the closed current visibility enum. `members.list` remains the separately actor-authorized management read, while `members.get` is resource-gated and has no actor input. See [Membership visibility](../groups/memberships.md#membership-directory-visibility).

## Service methods

`synex.groups@1` exposes the 70 server-only operation handlers through Core Services. The network-only `self.snapshot` projection is deliberately excluded. A service method is the contract suffix with dots changed to underscores:

```text
synex.groups.members.set_grade  ->  members_set_grade
synex.groups.members.set_visibility -> members_set_visibility
synex.groups.compatibility.resolve_target -> compatibility_resolve_target
synex.groups.compatibility.set_primary_grade -> compatibility_set_primary_grade
synex.groups.policies.simulate  ->  policies_simulate
synex.groups.definitions.sync   ->  definitions_sync
```

Every method retains its contract capability. Service calls do not bypass schema validation, caller identity, actor authorization, hooks, idempotency, or persistence rules.

## Mutation result and concurrency

Most entity mutations return:

```text
entity_id
entity_type
status
version
replayed
```

`synex.groups.definitions.sync` is the exception: it returns a bounded synchronization plan (`items`, `truncated`) rather than an entity result.

All mutations require `idempotency_key`. Operations that change existing versioned state also require `expected_version` where declared. A successful exact replay returns the recorded result with `replayed = true`; a key reused for a different canonical request is rejected.

Cursor-list reads return `truncated` plus an optional `next_cursor`. Relationship, duty, and assignment pages are bounded to 40 items; self snapshot pages to 8; other management lists retain their schema limit of at most 100. Every non-mutating Groups response is rejected above 30,000 encoded bytes, and relationship/assignment detail metadata is bounded to 16 KiB. Capability evaluation is bounded to 256 composed rules, 32 roles, 64 delegations, and 16 scope keys in the current pure domain defaults; persistence applies equal or tighter query limits.

## Lifecycles

The current pure domain transition graphs recognize:

- group: `draft`, `active`, `suspended`, `archived`, `dissolving`, `deleted`;
- membership: `DRAFT`, `INVITED`, `APPLICANT`, `UNDER_REVIEW`, `APPROVED`, `PROBATION`, `ACTIVE`, `SUSPENDED`, `LEAVE`, `INACTIVE`, `TERMINATED`, `BANNED`, `LEFT`, `ARCHIVED`;
- invitation: `pending`, `accepted`, `declined`, `revoked`, `expired`;
- application: `submitted`, `reviewing`, `approved`, `rejected`, `withdrawn`, `expired`;
- duty session: `open`, `closed`;
- assignment: `active`, `completed`, `cancelled`, `expired`;
- proposal: `pending`, `approved`, `rejected`, `executed`, `cancelled`, `expired`.

Not every stored state has a public operation in the current catalog. Schema allowance is not an API promise; see the topic-specific pages for exposed transitions.

The bounded maintenance worker automatically changes an elapsed `active` or `suspended` relationship to `ended`. The same transaction records `relationship.expired`, stores the reason `relationship_window_expired`, and advances both participating organizations' read-model revisions. A conflict or malformed edge fails the batch closed rather than publishing a partial expiry.

Every membership transition must first exist in the global lifecycle graph and in the owning group type's allowed state set. A group-local transition policy can then deny that route or require an exact character capability, an accepted proposal, a reason, or any combination of those constraints. Absence of a group-local row preserves the explicit compatibility default: allowed, `synex.groups.members.manage`, no approval, and a required reason. Proposal authority is supplied only by the closed internal proposal executor after it revalidates the locked durable action and quorum; callers cannot submit an approval token through `members.transition`.

## Events, audit, and history

Every successful mutation commits its command receipt and any resulting domain-state change in one transaction. Mutations that return a domain effect also write domain history, Core-audit delivery intent, and a durable outbox event in that transaction. The validated operation trace is the history correlation and the emitted event trace; legacy rows without a stored correlation fall back to `event_id`. `definitions.sync` returns a bounded synchronization plan; a static group that is created or reconciled also produces the corresponding internal domain effect, while an unchanged or catalog-only item does not manufacture a group-change event. Outbox delivery is at least once, so consumers deduplicate on `event_id`. Core audit delivery retries separately and can become `dead` after its bounded attempt policy; Doctor reports dead deliveries.

`synex.groups.history.list` is the authorized read surface for newest-first before/after domain history. Direct reads from history or operational tables are unsupported integration behavior.

## Diagnostics

The `synex.groups.doctor` contract and `synex doctor groups` operator command report a bounded read-only integrity summary. The current implementation checks orphan/missing references, duplicate active membership, overdue authority, hierarchy/reporting cycles, dangling relationships, capability/scope/policy defects, definition drift, invalid duty/assignment state, dead audit delivery, and stale command receipts. It also reports bounded read-model-cache, revision-keyed definition-cache, and owner-registry statistics. Definition-cache metrics include size, maximum, hits, misses, writes, invalidations, evictions, and clears; cache values are defensively copied and restart empty.

The optional Experimental-Alpha `synex_control` provider adds read-only operator projections without bypassing Groups. Its Group inspector reports member, on-duty, grade, role and subgroup counts plus integrity state and bounded related-view links. Its Membership inspector attaches at most eight active roles, duty sessions, assignments and effective received delegations per section. Its `character_relations` inspector reports the exact organization-link count and at most eight membership links for one exact Character. Exact Group/Membership search and the metadata-driven policy-simulation view call existing Groups read/evaluation paths; simulation requires a bounded actor Character ID, Group ID and action, accepts optional target membership/grade IDs, and persists nothing.

Doctor never repairs data and a `PASS` does not replace the Groups release gate.

The current automated coverage exercises the 71-contract surface, including the owner-epoch registry synchronization protocol, relationship/assignment/duty reads, relationship expiry, the revision-keyed definition cache, authorization preflights, the compatibility resolver/atomic mapping boundary, and the self-projection boundary. The uncommitted working tree also passed the dedicated disposable-MariaDB suite, fresh isolated FXServer boot, Groups/Core restart recovery, and Doctor checks. The manual client projection smoke, exact committed-revision review, and explicit owner maturity/publication decision remain open. See [Testing](../testing.md#current-groups-alpha-evidence) for the complete evidence boundary. This does not move Groups beyond Experimental Alpha.

## Topic guides

- [Groups and types](../groups/groups.md)
- [Memberships](../groups/memberships.md)
- [Grades and roles](../groups/grades-and-roles.md)
- [Capabilities](../groups/capabilities.md)
- [Policies](../groups/policies.md)
- [Duty](../groups/duty.md)
- [Assignments](../groups/assignments.md)
- [Delegations](../groups/delegations.md)
- [Approvals](../groups/approvals.md)
- [Relationships](../groups/relationships.md)
- [Custom types and definitions](../groups/custom-group-types.md)
- [Development](../groups/development.md)
