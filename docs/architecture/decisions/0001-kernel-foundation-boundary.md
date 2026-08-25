# ADR-0001: Kernel and foundation split

Status: Accepted

Scope: architecture direction. Only the `synex_core` side is in the accepted Production-Beta profile; every named foundation or gameplay resource is a rework target, not an accepted implementation.

## Context

Player-facing gameplay domains evolve independently, while lifecycle, identity, policy, communication, and persistence boundaries must remain coherent.

## Decision

Keep `synex_core` limited to kernel responsibilities. Keep groups, accounts, entity authority, and the control plane in separate foundation-resource boundaries as they are reworked. Phone, inventory, banking UI, garages, and similar gameplay systems are not kernel features.

## Consequences

The kernel stays small enough to audit. The checked-in foundation snapshots illustrate the intended versioned gateway and ownership boundaries, but their current lifecycle behavior is not part of Core acceptance and must be revalidated after rework.
