# Cancellation and cleanup

Cancellation is an explicit server-controlled transition, not a client assertion that a persistent side effect was undone.

## Public reasons

The shared lifecycle vocabulary is closed and uses the following stable reasons:

```text
USER_CANCELLED  ACTOR_MOVED  ACTOR_DIED  ACTOR_RAGDOLL  ACTOR_DAMAGED
TARGET_MOVED    TARGET_GONE  OUT_OF_RANGE  WORLD_CHANGED
WORLD_REF_STALE  ENTITY_REF_STALE  SLOT_LOST  CAPABILITY_REVOKED
TARGET_STATE_CHANGED  RESOURCE_STOPPED  TIMEOUT  DOMAIN_REJECTED
```

The client cancellation contract accepts only the observable subset plus `USER_CANCELLED`; it cannot claim capability revocation, domain rejection or resource lifecycle failures. A configured vehicle transition uses `TARGET_STATE_CHANGED`. Internal lifecycle paths can additionally cancel for participant loss, lease expiry, owner replacement or runtime shutdown. Public errors use stable codes and do not expose internal stacks.

## Policy

`graph.cancelPolicy` defines graph defaults. `executionPolicy.cancel` may override them for one intent. Both objects reject unknown keys and support:

```text
cancelOnMove          actorMoveDistance
cancelOnDamage        cancelOnDeath        cancelOnRagdoll
cancelOnVehicleChange
cancelOnTargetMove    targetMoveDistance
cancelOnTargetLoss    targetLossGraceMs
cancelOnWorldChange
cancelDistance        distanceHysteresis   distanceGraceMs
```

The compiled client projection contains only this merged, bounded cancellation policy; permission and execution internals remain server-only. The client observes movement, health loss, death, ragdoll, vehicle/world transitions and target continuity, then requests cancellation with the corresponding public reason. It never validates or commits a domain side effect.

Distance cancellation uses a Schmitt trigger. Crossing `cancelDistance + distanceHysteresis` starts the grace period; the pending violation clears only below `cancelDistance - distanceHysteresis`. This avoids boundary jitter. There is no global movement or distance policy: unset flags stay disabled.

Every lease renewal revalidates the active source generation/session participant, server-side actor ped health, bundle and intent revision/owner epoch, runtime dependencies, canonical target/World revision and range, availability, reservation and current server policy before extending the bounded maximum lifetime. Running graphs renew internally without a client heartbeat; a manual facade/service renewal is capability- and owner-epoch-bound. A stale client context cannot revoke another valid actor lease; a failed authoritative revalidation applies the affected participant/session cleanup path.

## Idempotent cleanup

Cancellation marks the execution/session, releases slot reservations/occupancy, actor locks, leases and pending presentation, then removes terminal runtime records. Repeating cleanup is safe. A bounded round-robin server sweep checks at most 64 tracked leases per scheduled tick; a dead or unavailable actor triggers `ACTOR_DIED` cleanup without relying on a client cancellation message. Presentation cleanup uses the current resource epoch/revision so an old callback cannot remove a new owner's surface.

Restart safety is intentionally fail-closed. Process-local interactions do not resume after `synex_interact` restarts; durable domains recover their own committed state and may offer a fresh interaction later.
