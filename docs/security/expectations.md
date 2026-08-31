# Security expectations

Expectations describe unusual states that are currently legitimate. They reduce
false positives without granting gameplay or domain authority.

## Model

An expectation contains:

- a generated or caller-supplied `expectationId`;
- the caller-owned namespace and one canonical kind;
- a player, user, character, or resource subject;
- explicit signal selectors;
- a bounded reason and TTL;
- the Core-derived owner resource and owner epoch;
- issue/expiry timestamps and a revision.

Supported kinds are:

```text
combat.invulnerable   combat.passive      visibility.hidden
movement.teleport     movement.noclip     camera.spectate
camera.freecam        player.model        weapon.grant
entity.spawn
```

Kinds provide a mandatory category boundary; explicit selectors narrow the
match further. Movement kinds cannot suppress economy, combat, entity, or other
unrelated domain signals, even when a privileged owner supplies a malformed
selector set.

## Constraints

At least one selector is required. Supported selectors are:

- `categories`;
- `detectors`;
- `codes`;
- `correlationKeys`;
- `evidenceClasses`;
- `worldKeys`;
- `entityIds`;
- `maximumSeverity` as an additional upper bound.

Selectors are dense, duplicate-free arrays. A request may contain at most 32
selector entries. Empty catch-all expectations are rejected.

## Ownership and lifecycle

Only the current resource incarnation can create, revise, or revoke its
expectations. A namespace must be owned by that resource. Updates and revocations
require the current revision. The registry permits at most 4,096 active
expectations globally and 256 per owner.

TTL is mandatory and ranges from 100 ms to 300,000 ms. Expired entries are
pruned. A resource stop, owner-epoch advance, or replacement revokes the old
owner's entries. Expectations are process-local and are not durable permissions.

## Matching

Subject identity and every supplied constraint must match. Session expectations
also match the source generation and, when provided, the source. World and entity
selectors are compared to the canonical references carried by a signal.

A matching signal is retained in bounded operational accounting but excluded
from actionable correlation. Expectations do not retroactively authorize the
underlying operation and do not alter an Accounts, Entities, World, or Interact
decision.

## Public API

The experimental service exposes `registerExpectation`, `revokeExpectation`,
and bounded listing methods. The first two require
`synex.security.expectation.manage`; reads require
`synex.security.case.read`. Core supplies caller identity and epoch.

The World integration can use a short-lived `movement.teleport` expectation
around a valid portal transition. Other domains should use the same pattern for
spawn protection, medical state, administrative spectate, or an authorized
entity spawn: issue narrowly, include a reason, bind the exact subject and
selectors, and revoke early when possible.

## Limitations

An expectation says only that a matching observation is expected. It is not a
capability, permission, lease, or domain grant. Live restart timing and domain
integration remain unverified until real FXServer testing.
