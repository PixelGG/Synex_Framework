# Access evaluation

World access is a server-side composable gate. It explains why access was allowed or denied, but it does not replace the capabilities enforced by Core on the public contract itself.

## Evaluation order

For a resolved target, the current evaluator checks:

1. active map package and dependency resource state;
2. disabled portal or `DISABLED` door state;
3. optional same-instance requirement;
4. zero or more primitive world-state requirements using `equals` or `not_equals`;
5. optional Groups capability for one group and `group`/`subtree` scope.

Requests using a player source require an active Core session and character. Server-only checks may instead use a character ID. The target is resolved from a key or revisioned `WorldRef`.

## Access policy

```json
{
  "requiredCapability": "police.armory.use",
  "groupId": "group:police",
  "scope": "group",
  "requireSameInstance": true,
  "stateRequirements": [
    {
      "key": "synex_world_companion:site.lockdown",
      "scopeRef": "synex_world_companion:site",
      "operator": "equals",
      "value": false
    }
  ]
}
```

`requiredCapability` and `groupId` must be supplied together. State comparisons accept only primitive boolean, integer/number, string or enum values that satisfy the referenced definition's type, bounds, length and allowed set; structured values are deliberately unavailable in access policies. Global and instance definitions reject an explicit `scopeRef`. Other explicit scopes must match the definition scope, and both the target and explicit scope must remain inside the definition parent's World hierarchy. Bundle activation and offline validation enforce the same rules fail-closed.

## Decisions

The compact check returns `ALLOW`/`DENY`, a reason and target reference. The explain path also returns the bounded gate-by-gate evaluation. Unavailable map or Groups dependencies fail closed; no policy reads Groups, Entities or Accounts tables directly.

Tags, client context, network ownership and DoorSystem state are never authorization evidence.
