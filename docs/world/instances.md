# World instances

An instance combines a declarative `instance_template` with an in-memory runtime record and a managed routing bucket owned by `synex_entities`.

Ordinary locations, MLO interiors and rooms never receive a routing bucket automatically. Buckets are reserved for an explicit `instance_template` isolation flow.

## Template

Templates define:

- a base `location` reference;
- entry and exit positions;
- capacity from 1 through 256;
- a TTL from 1 through 86,400 seconds only for `empty_ttl`;
- isolation profile: `isolated_strict`, `session`, `character_selection` or `custom`;
- cleanup policy metadata: `empty_ttl`, `owner_stop` or `manual`.

## Runtime lifecycle

```text
CREATING -> READY -> ACTIVE -> READY
                    |          |
                    +-> DRAINING -> CLOSED
                         \-> FAILED
```

Creation checks the current template hierarchy and map-package availability before calling `synex.entities.bucket.create@2.0.0`. It disables population and bounds player/entity capacity. World allocates separate, stable Core-compatible identities for bucket creation and destruction instead of forwarding the gameplay caller's key downstream. After the potentially yielding Entity call, World fences the template revision, registry revision and map generation again. A stale or unavailable result is destroyed and is never exposed as `READY`.

Join verifies the active source session, prevents membership in two instances and requires the template hierarchy to remain available before and after `synex.entities.bucket.move_player`. A session, template or map change after the move causes a separately idempotent move back to bucket `0`; no membership is committed.

Leave is the server-authoritative `instance_template.exit` path. World captures the compiled exit when the instance is created, reserves a bounded transition grant and independent 8–36 byte Entity move/rollback identities before moving the player to bucket `0`. It then rechecks session/source generation, membership, bucket generation, template revision, registry revision and map generation. Only after membership has been removed does the server send the closed `synex_world:client:apply_transition` payload containing the captured template exit. Callers cannot supply coordinates. The leave output reports `transitioned: true` and its bounded `grantId`.

Close uses the same exit path for every connected member, then destroys the generation-fenced bucket and only then marks the record closed. Its output reports `transitionedMembers`; stale disconnected memberships are removed without projecting a transition.

The public experimental contracts are `synex.world.instance.create`, `.join`, `.leave` and `.close`; all are server-only. Create requires `synex.world.instance.create`; the others require `synex.world.instance.manage`.

## Cleanup and persistence

Current instance records are process-local and are not stored in MariaDB. Player drop removes membership. `empty_ttl` starts its timer only while the instance is empty; joining cancels it and returning to empty restarts it. `owner_stop` closes the matching owner epoch when that resource stops. `manual` closes only through the owned close contract (World shutdown still performs safety cleanup for every live bucket).

Durable Core idempotency receipts for instance create/join/leave/close are scoped to one `synex_world` process incarnation. A retry in the same process can replay normally; an exact retry after a World restart conflicts fail-closed instead of returning a stale success for a process-local record or routing bucket.

Instance ownership and template ownership are independent. Deactivating or replacing an `instance_template` drains every live instance that still references that definition, including instances owned by another gameplay resource. A map-resource outage applies the same fail-safe behavior when the template or its base-location hierarchy becomes unavailable: each connected member is moved to bucket `0` and receives only the immutable, server-captured template exit; then the generation-fenced bucket is destroyed. Cleanup is allowed to use that captured exit when the live definition or map has just become unavailable, but it still fences the registry/map generation around every yielding move. Recovery never revives the old record. Cleanup failures remain pending, are retried by the bounded map reconciliation worker, degrade World health and emit a redacted audit signal.

An indeterminate bucket-create response is not treated as proof that no bucket exists. The failed record remains visible and enters a bounded recovery queue. The worker replays `bucket.create@2.0.0` with the exact stored request and stable downstream key, immediately destroys any recovered orphan with the record's independent destroy key, and only then reaches `CLOSED`. The same queue retries a failed final bucket destroy. Owner stop during a yielding create follows this path, so it cannot hide a side-effecting create behind a closed record. Recovery processes at most 25 entries per worker pass, never revives the failed instance, exposes `pendingBucketRecoveries`, emits redacted failure audits and holds health reason `INSTANCE_BUCKET_RECOVERY_FAILED` until empty.

At most 4,096 exit reservations may be in flight. Reservations are owned by the current instance mutation and are removed on success, rejection or unexpected handler failure. Client transition grant IDs and all downstream Entity idempotency identities are at most 36 bytes; keys are generated independently rather than truncated.

After the generation-fenced bucket is destroyed, World purges both runtime and persistent state rows whose scope is that instance ID. Cleanup is bounded to the owned World-state store. A cleanup failure does not resurrect the already closed bucket: it enters a bounded 2,048-entry retry queue, degrades World health and emits a redacted metric/audit signal. The instance worker retries at most 25 entries per pass and clears the reason only when the queue is empty. Live records plus pending state cleanups share the 2,048 admission bound, so repeated failures apply backpressure instead of losing cleanup work or growing memory.

At most 2,048 non-closed records and 1,024 recently closed records are retained. Closed history is evicted deterministically in closure order; a replay remains available while its record is retained and returns `INSTANCE_NOT_FOUND` after eviction. A definite non-retryable create failure that acquired no bucket becomes terminal immediately and does not consume live capacity; indeterminate failures retain capacity until orphan reconciliation completes. Summary counters are maintained incrementally, while the bounded list reads a mutation-maintained instance-ID index instead of sorting the full registry per request.

Routing-bucket behavior is delegated through Entity contracts rather than direct cross-domain SQL or unmanaged bucket natives. Live bucket isolation, restart and failure cleanup remain part of the open FXServer/OneSync acceptance work.
