# Applications, proposals, and creation approvals

> [!NOTE]
> This page documents the current Experimental Alpha. See [Organizations Engine status](overview.md#maturity-and-acceptance) before deploying it.

The Organizations Engine has three separate decision flows:

- an **application** is a character request to join a group;
- a **proposal** is a group-internal request that gathers membership approvals;
- a **creation request** is generated when a dynamic group type requires independent approval before creation.

None of these flows accepts executable Lua, arbitrary handler names, client callbacks, or direct database statements.

## Membership applications

`synex.groups.applications.submit` is self-bound to the actor character. It requires the current group-type schema version and validates bounded form data against that type's registered, closed `application_schema`. A type without a schema does not accept applications.

`synex.groups.applications.review` records an authorized `approved` or `rejected` decision with optimistic versioning and a reason. Approval rechecks active group state, member and grade capacity, and required/default attribute schemas before atomically creating the active membership and assigning the lowest-ranked active grade. `synex.groups.applications.withdraw` lets the applicant close a submitted or reviewing application. Maintenance expires overdue open applications.

See [Memberships](memberships.md#applications).

## Group-internal proposals

A proposal records:

- group, closed action key, and bounded JSON payload;
- required approval count;
- creator membership and group version at creation;
- expiry, lifecycle status, reason, and optimistic version.

Each decision records the approver membership, decision, reason, and observed permission/read-model revision. The creator cannot decide their own proposal, and a membership can decide a proposal only once.

Current contracts are `synex.groups.proposals.create`, `.approve`, and `.reject`. They require `synex.groups.approvals.manage` at the calling-resource and character layers.

### Bounded execution map

There is no public arbitrary proposal executor. Reaching quorum invokes one closed server-side mutation map inside the decision transaction:

| Proposal action | Groups mutation |
| --- | --- |
| `group.update` | update the group |
| `group.archive` | archive the group |
| `membership.transition` | transition a membership |
| `membership.set_grade` | change a membership grade |
| `membership.set_primary_grade` | atomically change an active self-owned membership's grade and primary selection |
| `role.assign` | assign a role |
| `role.remove` | remove a role assignment |
| `policy.set` | replace a contextual policy |
| `relationship.update` | update a relationship |

Creation rejects unknown actions and invalid payloads. At final approval the executor re-decodes the persisted payload, binds the proposal identity, requires the captured group revision to remain current, runs immutable `before_proposal_execute` and exact target-operation hooks, revalidates the request, and invokes the ordinary server-side mutation. Normal actions retain the approving actor. The compatibility `membership.set_primary_grade` action instead resolves the affected character from the locked target membership so the existing self-primary rule remains authoritative; approval quorum does not turn the approver or Bridge resource into a synthetic actor. Hook output cannot alter approved content. Any target failure rolls back the decision.

The proposal engine never executes account, inventory, vehicle, world, payroll, or other resource behavior. A downstream resource reacts to committed facts through its own server-authoritative and idempotent boundary.

## Dynamic group creation approvals

A group type may configure:

- `create_permission`, required for the requesting character;
- `required_approvals` from 0 through 32;
- `approval_permission`, required for each independent approver.

When the quorum is positive, `synex.groups.create` stores a 48-hour pending creation request and reserves its slug instead of creating the group. The current public flow is:

| Contract | Purpose |
| --- | --- |
| `synex.groups.creation_requests.get` | Read the request as its creator or an authorized approver |
| `synex.groups.creation_requests.approve` | Add one independent approval using `expected_version` |
| `synex.groups.creation_requests.reject` | Reject the request and release its slug reservation |

The creator cannot decide their own request, one character cannot decide twice, and the first rejection is terminal. Reaching quorum changes the durable request to `approved`. The post-commit coordinator attempts execution immediately, while a Core-scheduled Groups reconciliation worker resumes approved requests after failures or restarts.

Execution revalidates the creator permission, every approver permission, type schema/version and approval policy, immutable request body, and slug reservation. It creates the organization only if all checks still pass, transfers the reservation to the group, and records `executed`. Expired requests release their reservation. Approved requests are restart-recoverable and are not trusted merely because a counter reached quorum.

## Membership-transition approval

A configured [membership-transition policy](policies.md#membership-transition-policies) can require an approved proposal for one exact `from_status -> to_status` route. Direct `synex.groups.members.transition` then returns `APPROVAL_REQUIRED`; the same closed `membership.transition` proposal action supplies the internal approved-proposal context after quorum. Callers cannot forge that context through the public contract.

## Concurrency boundary

Proposal and creation-request decisions lock their aggregate, require `expected_version`, and use unique decision constraints. Creation slugs have an independent reservation key shared with direct group creation. The local Alpha database suite exercised these paths with independent connections; repeat the full gate for every changed revision.
