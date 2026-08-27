# Grades and roles

> [!NOTE]
> This page documents the current Experimental Alpha. See [Organizations Engine status](overview.md#maturity-and-acceptance) before deploying it.

Grades and roles solve different problems and are persisted separately.

## Grades

A grade is a membership's single position in the formal rank structure. It has a group-local key, label, signed rank, optional active-member capacity, active/disabled status, capability rules, and optimistic version.

Rank is ordering and policy context, not a permission check. Consumers ask for named capabilities rather than comparing grade numbers.

Current contracts are:

- `synex.groups.grades.create`;
- `synex.groups.grades.update`;
- `synex.groups.members.set_grade`;
- `synex.groups.compatibility.resolve_target` for an exact read-only group/grade lookup;
- `synex.groups.compatibility.set_primary_grade` for one reviewed compatibility mapping.

Definition changes and grade placement require `synex.groups.grades.manage`. A grade change locks the membership and destination grade, checks group ownership, actor rank over current and destination positions, capacity, expected membership version, contextual policy, and any internal approved-proposal requirement before advancing history and read models.

The compatibility mutation does not weaken those checks. Its caller also needs the narrow `synex.groups.compatibility.set_primary_grade` resource capability, while the affected character must own an active membership and satisfy the native grade policy through a sealed `membership.set_primary_grade` proposal. `expected_primary_version = 0` asserts that no primary row exists; positive values compare against the current primary revision. The grade and primary writes share one idempotent transaction, so either both commit or neither does. The resolver is read-only and returns no authorization grant.

Every dynamically created group also receives a reserved Owner recovery grade. A group type may add bounded default grades; a static group definition owns its declared grade set through reconciliation.

## Roles

A role is an additional responsibility. It has a group-local key, label, optional description, active/disabled/retired state, optional holder capacity, optional single-holder exclusivity, capability rules, and optimistic version.

A membership may hold multiple roles. Assignments can have `valid_from` and `valid_until`; expired assignments stop contributing authority immediately and maintenance records expiry. Removal is a versioned, reasoned revocation rather than row deletion.

Exclusive roles use an active-marker uniqueness constraint. Capacity provides a broader holder limit. Updates cannot lower capacity below active holders or deactivate a role that remains assigned.

Current contracts are:

- `synex.groups.roles.create` and `.update`;
- `synex.groups.roles.assign` and `.remove`.

They require `synex.groups.roles.manage` at the Core caller-resource boundary and for actor-driven group authority.

## Capability rules

`synex.groups.capabilities.set` attaches `allow` or `deny` rules to groups, grades, roles, or individual memberships. For grade and role definitions, those rules describe the authority inherited by active holders. Rules support group/subtree scope and explicit delegability; a deny cannot be delegable.

Effective evaluation combines group defaults, grade, active non-expired roles, direct membership rules, and active non-expired delegations. Any matching deny wins. See [Capabilities](capabilities.md).

## Example

```text
Membership: Officer Smith
Grade:      Sergeant
Roles:      Field Training Officer, Recruiter
```

The grade represents formal position; roles represent independent responsibilities. The integrating police resource owns what those names mean and which gameplay capabilities they carry.

## Concurrency

- Grade and role definitions use `expected_version` on update.
- Grade changes use the membership version.
- Role removals use the role-assignment version.
- Capacity and exclusivity checks run under transactional locks and relational constraints.
- Successful changes advance read-model invalidation and durable domain effects.
