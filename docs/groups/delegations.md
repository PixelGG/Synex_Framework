# Delegations

> [!NOTE]
> This page documents the current Experimental Alpha. See [Organizations Engine status](overview.md#maturity-and-acceptance) before deploying it.

A delegation is a temporary grant from one active group membership to another. It adds one bounded capability source; it does not copy a grade or role and never grants a Core resource capability.

## Creation rules

`synex.groups.delegations.create` requires:

- an active group;
- a grantor with `synex.groups.delegations.manage`;
- the grantor to currently possess the exact requested capability and scope;
- that effective capability to be explicitly marked `delegable` by its source rule;
- a different, active grantee membership in the same group;
- `group` or `subtree` scope;
- a future `valid_until` after optional `valid_from`;
- a reason and idempotency key.

Wildcard capabilities are rejected. Deny rules cannot be delegable, and a capability received through delegation is not re-delegable. An equivalent active, unexpired grant for the same grantee/capability/scope is rejected.

Both management authority and the delegated capability pass through the shared capability-plus-policy boundary. An exact stored policy may therefore deny either decision.

## Revocation and expiry

`synex.groups.delegations.revoke` requires `synex.groups.delegations.manage`, the current delegation version, and a reason. It changes only an active grant to `revoked`, records the revocation time, advances the group read model, and emits a domain effect.

Bounded maintenance marks overdue active grants `expired`. Effective evaluation also filters by current validity time, so an overdue grant stops authorizing immediately even before maintenance rewrites its status.

## Capability composition

Delegations contribute an `allow` rule for one exact capability and scope. They do not override any matching deny from group defaults, grade, roles, or direct membership rules.

```text
matching allows
- any matching deny
= effective decision
```

See [Capabilities](capabilities.md) for source composition and explanation output.

## Domain boundary

- A delegation targets a durable membership, not an online source ID.
- It remains stored while the player is offline.
- Leaving active membership state revokes current delegation authority according to lifecycle cleanup.
- The grant authorizes only the named domain operation; it transfers no ownership, money, inventory, vehicle, or caller-resource access.
