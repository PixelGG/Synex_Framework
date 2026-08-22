# ADR-0001: Kernel and foundation split

Status: Accepted

## Context

Player-facing gameplay domains evolve independently, while lifecycle, identity, policy, communication, and persistence boundaries must remain coherent.

## Decision

Keep `synex_core` limited to kernel responsibilities. Implement groups, accounts, entity authority, and the control plane as foundation resources. Phone, inventory, banking UI, garages, and similar gameplay systems are not kernel features.

## Consequences

The kernel stays small enough to audit. Foundation resources use the same versioned gateways as third-party resources and can be restarted or replaced within their declared lifecycle limits.
