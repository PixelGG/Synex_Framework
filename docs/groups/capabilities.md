# Capabilities

> [!NOTE]
> This page documents the current Experimental Alpha. See [Organizations Engine status](overview.md#maturity-and-acceptance) before deploying it.

`synex_groups` uses named capabilities rather than gameplay checks against grade numbers or role labels.

## Two independent permission layers

Every server-resource call is first checked by Core against the calling **resource**. Actor-driven operations then evaluate the **character** inside the target organization.

```text
Calling resource capability
        AND
Actor character's effective group capability and active policy
        =
Operation may continue
```

A character capability never lets an undeclared resource call a server contract, and a resource grant never lets a caller select an unauthorized actor character. The sole client contract, `synex.groups.self.snapshot`, is a separate read-only boundary: Core derives the character from an active session, and the client cannot supply an actor or target character.

## Effective character authority

The persisted evaluator composes bounded rules from:

1. group defaults;
2. the active membership's grade;
3. active, currently valid role assignments;
4. rules attached directly to the active membership;
5. active, currently valid delegations.

Rules carry a lowercase capability pattern, `allow` or `deny`, a `group` or `subtree` scope, a `delegable` flag where applicable, and source-specific validity windows. Exact names and terminal `.*` wildcards are recognized. A wildcard does not match another prefix.

An active stored [policy](policies.md) is a contextual gate evaluated after base capability composition. It cannot restore authority that the base evaluator denied.

## Revision-bound definition cache

Group-default, grade, role-source, and stored-policy definitions use a bounded in-memory cache keyed by durable revision. The evaluator obtains the current database revision and verifies it again before returning a decision; it does not accept a time-to-live entry as authority. Mutations invalidate affected group entries, while role and delegation validity windows are still evaluated against the current database/application clock so a cache hit cannot prolong expired authority.

`synex.groups.doctor` exposes only counters and capacity under `cache.definitions`. Cached rules themselves are not part of the public diagnostic response.

## Deny wins

Evaluation is deterministic:

- at least one matching allow with no matching deny produces `ALLOW`;
- any matching deny produces `DENY`;
- no matching allow produces `DENY`;
- invalid, oversized, expired, revoked, inactive, or scope-mismatched inputs fail closed or do not match as reported by the trace.

Grade rank and role assignment order do not grant precedence.

## Scopes and delegability

The public rule/check surfaces accept `group` or `subtree`. Scope is part of the decision input, not a suffix added after authorization. Consumers must send the target group and intended scope and must not reuse a decision for another organization.

An allow rule may be marked `delegable`; deny rules cannot. `synex.groups.delegations.create` succeeds only when the grantor's effective evaluation both allows the exact requested capability and reports it as explicitly delegable. A delegated rule is never itself delegable.

## Check and explain

`synex.groups.capabilities.check` and `synex.groups.capabilities.explain` require the calling resource capability `synex.groups.read`. Both currently use the common structured evaluator response, including:

- `decision`: `ALLOW` or `DENY`;
- stable reason code;
- character, group, capability, and scope;
- bounded trace ID and evaluation items;
- the resulting `delegable` flag.

When `actor_character_id` differs from `character_id`, that actor must also hold `synex.groups.capabilities.read` in the group. Without a different actor, the handler evaluates the subject but adds no separate character-level inspection gate beyond Core's caller-resource capability. Do not expose this server-local read directly to clients.

Human-readable messages are not stable API. Branch on declared result fields and error codes.

## Defining rules

`synex.groups.capabilities.set` attaches an `allow` or `deny` rule to one of four source types:

- `group`, where `source_id` is the target group;
- `grade`;
- `role`;
- `membership`.

The request includes capability, effect, optional `group`/`subtree` scope, optional delegability, actor, and idempotency key. Replacing an existing rule requires its current `expected_version`. The source must be active, the actor needs `synex.groups.capabilities.manage`, and a successful change advances the group read model.

## Gameplay usage

Ask the domain question directly from a server resource:

```lua
local result, checkError = api.RPC.call(
    'synex.groups.capabilities.check',
    '1.0.0',
    {
        character_id = characterId,
        group_id = groupId,
        capability = 'police.evidence.delete',
        scope = 'group'
    },
    { timeoutMs = 3000 }
)
```

Avoid rank shortcuts:

```lua
-- Wrong: rank ordering is not an authorization contract.
if grade >= 4 then
    -- ...
end
```

The capability name belongs to the gameplay resource that owns the action. `synex_groups` evaluates organization authority; it does not execute the police, medical, account, inventory, or world mutation.
