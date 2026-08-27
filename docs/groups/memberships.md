# Memberships

> [!NOTE]
> This page documents the current Experimental Alpha. See [Organizations Engine status](overview.md#maturity-and-acceptance) before deploying it.

A membership is a first-class, durable relationship between one character and one group. It is not a boolean and is not derived from the player's online state.

## Model

The character membership model records:

- an opaque public membership ID;
- group and character references;
- lifecycle state and directory visibility;
- join, suspension, and departure timestamps where applicable;
- one current grade and zero or more roles;
- optional typed attributes;
- optimistic versions and group read-model revision;
- append-only membership and domain history plus durable event intent.

At most one membership entity exists for a character/group pair; its lifecycle advances instead of creating duplicate active rows. One character may hold memberships in multiple groups, and all supported reads and mutations work while that character is offline.

## Lifecycle

The domain graph includes the following states:

```text
DRAFT -> INVITED | APPLICANT | PROBATION | ACTIVE | INACTIVE | BANNED | ARCHIVED
INVITED -> DRAFT | PROBATION | ACTIVE | BANNED | ARCHIVED
APPLICANT -> DRAFT | UNDER_REVIEW | APPROVED | PROBATION | ACTIVE | BANNED | ARCHIVED
UNDER_REVIEW -> DRAFT | APPROVED | BANNED | ARCHIVED
APPROVED -> PROBATION | ACTIVE | BANNED | ARCHIVED
PROBATION | ACTIVE | SUSPENDED | LEAVE | INACTIVE -> allowed non-terminal routes
PROBATION | ACTIVE | SUSPENDED | LEAVE | INACTIVE -> TERMINATED | BANNED | LEFT | ARCHIVED
```

`TERMINATED`, `BANNED`, `LEFT`, and `ARCHIVED` are terminal. The complete exact graph lives in the domain constants; group types may further restrict the states valid for their organizations.

Group-specific transition policies may additionally deny an otherwise valid route, require a specific exact capability, require execution from an approved Groups proposal, and decide whether a non-empty reason is mandatory. An unconfigured route uses the compatibility policy: allowed, `synex.groups.members.manage`, no proposal required, reason required. See [Membership-transition policies](policies.md#membership-transition-policies).

Leaving `ACTIVE` closes open duty. Terminal transitions also revoke active roles and delegations, remove assignment participation and primary selection, and retain the membership/history rows. Entering `ACTIVE` rechecks group and grade capacity and validates or materializes all effective required/default attribute schemas in the same transaction.

## Invitations

`synex.groups.members.invite` creates one pending invitation for a character/group pair with an optional grade, bounded role list, expiry, and reason. Creating the invitation also materializes the pair's permanent membership entity in `INVITED`: it is hidden, has no join timestamp or grade, and the invitation stores that membership ID.

- `synex.groups.members.accept` is self-bound to the invited character and atomically rechecks expiry, capacities, grade, roles, activation attributes, and the allowed activation route. It advances the same membership to `ACTIVE`, or to an allowed configured `PROBATION` route, and only then sets its join timestamp.
- `synex.groups.members.decline` lets that character close a pending invitation with its current version and a reason, returning the linked membership to hidden `DRAFT`.
- `synex.groups.members.revoke_invite` lets an authorized manager revoke it with its current version and a reason, returning the linked membership to hidden `DRAFT`.

Bounded maintenance expires overdue pending invitations and returns their memberships to `DRAFT` with membership history and durable event intent in the same transaction. Accepted, declined, revoked, and expired invitation records retain the permanent membership reference as workflow history. A later invitation reuses that entity instead of violating character/group uniqueness.

## Applications

`synex.groups.applications.submit` accepts only the actor's own application and validates its bounded data against the current type's closed `application_schema`. Types without a schema fail closed, and one open application per character/group is permitted. Submission materializes or reuses the pair's hidden durable membership in `APPLICANT`; the application stores that membership ID.

`synex.groups.applications.review` first advances both the submitted application and its membership to `under_review` / `UNDER_REVIEW`. A later authorized decision records `approved` and `APPROVED` before activating that same membership, or records `rejected` and returns it to `DRAFT`. Approval, membership activation, default-grade assignment, capacity checks, required attribute materialization, history, and durable effects share one transaction; any activation failure rolls back the decision. Every review step requires the current `expected_version` and a reason.

`synex.groups.applications.withdraw` returns a submitted or reviewing application's linked membership to `DRAFT` optimistically. Maintenance does the same for overdue open applications. Rejected, withdrawn, and expired records remain linked history, and a later application reuses the permanent membership entity.

## Grade, roles, and primary selection

- A membership has one current grade. Changes are versioned and enforce rank authority, destination capacity, policy, and any configured approval requirement.
- A membership may have multiple active, optionally time-bounded roles. See [Grades and roles](grades-and-roles.md).
- `synex.groups.members.set_primary` selects one active membership per character and group type.

Primary selection is a downstream preference projection. It does not remove other memberships or grant authority.

## Reporting structure

The reporting graph is independent from grade rank. `synex.groups.reporting.set` assigns or removes one active membership's direct manager inside the same group. It requires `expected_version`, a reason, and actor authority, rejects self-links and cycles, and rebuilds affected closure paths transactionally.

`members.get`, `members.list`, and `directory.list` expose the direct manager as `reports_to_public_id` when present. Consumers compose a bounded organization chart from authorized results rather than querying tables.

## Membership directory visibility

The membership profile visibility is separate from attribute visibility. `synex.groups.directory.list` applies it server-side:

| Stored visibility | Directory behavior |
| --- | --- |
| `public` | Returned after the calling resource passes the contract capability |
| `members` | Returned to an actor with an active membership in the group |
| `management` | Returned to an active actor with directory/member-read management authority |
| legacy `private` or `hidden` | Returned only for the actor's own character |
| `server_only` | Never returned by the directory contract |

`synex.groups.members.set_visibility` changes the profile to exactly one of `public`, `members`, `management`, `hidden`, or `server_only`. It requires the calling resource capability and actor capability `synex.groups.members.manage`, the current membership `expected_version`, a stable `idempotency_key`, and a reason. The update uses independent membership/profile CAS values inside one transaction, writes membership/domain history and durable event intent, runs `synex.groups.before_membership_visibility_change`, and invalidates the affected runtime/cache projections. Legacy `private` rows remain readable under their historical subject-only rule but cannot be newly selected through this contract.

Pre-join states (`DRAFT`, `INVITED`, `APPLICANT`, `UNDER_REVIEW`, and `APPROVED`) cannot be changed to `public`, `members`, or `management`; only `hidden` and `server_only` are accepted. Their `joined_at` field is absent until real activation and is never substituted with the record creation time.

`members.get` is a trusted server-resource read without an actor field. `members.list` is the management read and requires `synex.groups.members.read` inside the group. Neither is a client endpoint, and neither should replace the directory projection in a Phone/MDT-style integration.

Collections are cursor-bounded to at most 100 items. Honor `truncated` and `next_cursor`.

## Typed attributes

`synex.groups.attributes.get` reads one explicit attribute after its schema's visibility and optional capability checks. Schemas may be global or override the same namespace/key for one group type. Required schemas must have a type-valid default; activation atomically materializes that default when no value exists. See [Attribute schemas](custom-group-types.md#attribute-schemas).

## Character deletion

`synex_groups` registers a required Core character-lifecycle participant in anonymization mode. Its idempotent transaction closes or revokes current duty, role, assignment, delegation, invitation, application, membership, and primary state; replaces direct character/actor references with Core's anonymous reference; clears submitted form data; and redacts JSON that still contains the original reference.

Organization history remains durable but must no longer retain the deleted character reference. The local Alpha gate covered this lifecycle and replay boundary; repeat it for every changed revision.

## Current contracts

| Area | Contracts |
| --- | --- |
| Reads | `synex.groups.members.get`, `.list`, `synex.groups.directory.list` |
| Invitations | `synex.groups.members.invite`, `.accept`, `.decline`, `.revoke_invite` |
| Lifecycle and policy | `synex.groups.members.transition`, `.transition_policy.get`, `.transition_policy.set` |
| Placement and privacy | `synex.groups.members.set_grade`, `.set_visibility`, `.set_primary`, `synex.groups.reporting.set` |
| Applications | `synex.groups.applications.submit`, `.review`, `.withdraw` |
| Attributes | `synex.groups.attributes.get`, `.set` |

Mutation idempotency and version requirements are defined by the [generated contract catalog](../../packages/contracts/generated/docs/contracts.md).
