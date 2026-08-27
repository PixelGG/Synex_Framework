# Policies

> [!NOTE]
> This page documents the current Experimental Alpha. See [Organizations Engine status](overview.md#maturity-and-acceptance) before deploying it.

`synex_groups` implements two separate policy layers:

- **contextual action policies** refine an actor's already-effective capability for one group action;
- **membership-transition policies** configure one exact membership lifecycle route.

Neither layer replaces Core resource authorization, Groups character authority, lifecycle validation, optimistic concurrency, or operation-specific invariants.

## Contextual action policies

`synex.groups.policies.set` stores at most one policy per group and exact action key. A definition contains a display name, `allow` or `deny` default effect, `active`, `disabled`, or `retired` status, and at most 64 closed rules.

Each rule records:

- a stable key and signed priority;
- `allow` or `deny` effect;
- an exact action or terminal `.*` prefix pattern;
- `character` or `membership` subject kind;
- `global`, `group`, `relationship`, `assignment`, or `custom` scope, with a scope reference where required;
- an optional bounded condition.

Supported condition inputs are intentionally small:

- whether the target membership is active;
- whether the actor's grade rank is above the target's rank;
- one named operation parameter evaluated by `equals`, `not_equals`, `exists`, or membership in a bounded scalar `in` list.

Unknown definition or rule fields fail validation. Matching deny rules win over matching allow rules; otherwise the stored default effect applies. A disabled or retired policy is not evaluated as active.

### Evaluation order

For an operation using an action policy, Groups evaluates:

1. the caller resource's Core capability and the closed request schema;
2. a read-only persistence preflight that resolves the owning group, the character's effective Groups capability, and the active stored policy for the same action;
3. the preflight-approved character references through Core;
4. the bounded hook, followed by an authoritative transaction that repeats ownership, scope, lifecycle, approval, capacity, version, and authorization checks.

A policy can narrow an existing capability but cannot turn a failed capability evaluation into an allow. When no active policy exists, the stored-policy layer reports `NO_POLICY` and leaves the capability decision unchanged.

`synex.groups.policies.manage` is the recovery boundary: stored contextual policies do not evaluate against that capability, so an authorized policy administrator cannot permanently lock every repair path through a malformed or over-restrictive policy.

### Set and simulate

`synex.groups.policies.set` requires both caller-resource and in-group `synex.groups.policies.manage` authority. Updates require the current `expected_version`; the mutation replaces the rule set transactionally and emits `synex.groups.policy.changed` through the durable outbox path.

`synex.groups.policies.simulate` evaluates the actor's effective capability and the active contextual policy without performing the target mutation. Its trace is diagnostic evidence for a server integration, not an authorization token and not a substitute for calling the real mutation.

An approved `policy.set` proposal executes the same closed mutation path. Callers cannot supply an arbitrary executor or forge proposal context. See [Applications, proposals, and creation approvals](approvals.md#group-internal-proposals).

## Membership-transition policies

A membership-transition policy belongs to one group and one exact `from_status -> to_status` lifecycle route. `set` accepts only a route in the global membership lifecycle graph whose two states are enabled for the organization's group type. The transition operation rechecks both boundaries when it executes.

The server-only contracts are:

| Contract | Purpose |
| --- | --- |
| `synex.groups.members.transition_policy.get` | Read the configured route policy or its compatibility fallback |
| `synex.groups.members.transition_policy.set` | Create or version-update the policy for one route |

The equivalent `synex.groups@1` service methods are `members_transition_policy_get` and `members_transition_policy_set`. Both require caller-resource and actor `synex.groups.policies.manage` authority. `set` is idempotent. An existing record requires its current `expected_version`; a new route accepts no version or `expected_version = 1`.

Each route policy defines:

| Field | Effect during `synex.groups.members.transition` |
| --- | --- |
| `allowed` | A false value rejects the otherwise valid lifecycle route |
| `required_capability` | Exact, non-wildcard Groups capability required from the actor |
| `approval_required` | Requires the transition to execute from the sealed approved `membership.transition` proposal path |
| `reason_required` | Requires a non-empty transition reason |

An unconfigured valid route resolves to the compatibility policy:

```text
configured: false
allowed: true
required_capability: synex.groups.members.manage
approval_required: false
reason_required: true
```

The compatibility value is resolved at runtime; it is not presented as a persisted policy record. `set` runs `synex.groups.before_policy_change`; the lifecycle route, CAS version, flags, and required capability cannot be redirected by a hook patch. A successful `set` produces `synex.groups.membership.transition_policy.changed` and updates the group read-model revision.

If approval is required, a direct transition returns `APPROVAL_REQUIRED`. The proposal engine binds the exact persisted payload, approving actor, group, and operation before re-entering the ordinary transition handler. The policy, capability, reason, lifecycle, type-state, capacity, attribute, and version checks still run at execution time.

See [Membership lifecycle](memberships.md#lifecycle) for the base state graph and [Membership-transition approval](approvals.md#membership-transition-approval) for the sealed approval path.

## Security boundary

Policy contracts are server-only and `network: none`. Do not expose raw policy definitions, simulation parameters, transition flags, or proposal execution context through a client-trusted event. A gameplay resource may collect user intent, but its server must construct a bounded request and let Core and Groups perform the authoritative decision.

The exact schemas, versions, capabilities, and error sets live in the [generated contract catalog](../../packages/contracts/generated/docs/contracts.md).
