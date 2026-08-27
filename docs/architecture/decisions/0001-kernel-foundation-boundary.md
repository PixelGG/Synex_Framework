# ADR-0001: Kernel and foundation split

Status: Accepted

Scope: architecture direction. Only the frozen `synex_core` tree is in the accepted Production-Beta profile. `synex_groups` is the Experimental Alpha Organizations Engine; every other named foundation or gameplay resource remains a rework target. No downstream implementation is supported by the Core decision.

## Context

Player-facing gameplay domains evolve independently, while lifecycle, identity, policy, communication, and persistence boundaries must remain coherent.

## Decision

Keep `synex_core` limited to kernel responsibilities. Keep groups, accounts, entity authority, and the control plane in separate experimental foundation-resource boundaries with their own acceptance gates. Phone, inventory, banking UI, garages, and similar gameplay systems are not kernel features.

## Consequences

The kernel stays small enough to audit. The Groups Alpha exercises the intended versioned gateway, caller-bound DataPort, coordinated deletion, and ownership boundaries, while other checked-in foundation snapshots remain design inputs. No downstream lifecycle behavior is part of Core acceptance; each exact resource revision needs its own validation and release decision.
