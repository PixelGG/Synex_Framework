# Entity security

The Entity Authority Engine treats every client-originated value and every cross-resource caller as untrusted until the server boundary validates it.

## Exposure

- All generated Entity contracts declare `network: none`.
- The resource is `server_only` and has no NUI.
- A client cannot invoke spawn, delete, state, component or bucket contracts directly.
- A gameplay resource must authenticate/authorize its own client request, then call Core from its server context.

Core captures the immediate resource principal. Request options cannot assert another caller. Every public contract has a declared capability and rate limit; the provider repeats resource ownership and generation checks for the operation.

## Mutation fences

Depending on the operation, the server checks:

- contract schema and unknown keys;
- capability grant and denied-by-default destructive capability;
- current Core caller epoch;
- Entity ID plus generation;
- resource ownership and logical-owner validity;
- managed bucket ID plus generation and ownership;
- expected durable/component/state version;
- idempotency key and reason code;
- live Entity authority token and lease generation;
- native Entity type/model/bucket/NetID after creation and before use;
- total, resource, logical-owner, bucket, persistence/type quotas and spawn-rate budgets.

Client-supplied price, balance, inventory, permission, ownership or gameplay state is outside this resource and must never be inferred from a NetID or State Bag.

## Namespace ownership

Archetypes, component schemas, state schemas, tags and their reason codes are resource-owned. Schema registrations are epoch-bound. A resource cannot mutate another resource's extension namespace or use a stale registration after restart.

Logical `resource` ownership must match the caller. Character and Group owners are resolved through their authoritative server domains. A network owner is always labeled transport-only and grants no permission.

## Bounded data and work

Coordinates, hashes, identifiers, arrays, pages, JSON bytes/depth/keys, query results, recovery batches, drift batches, cleanup deadlines and native waits have explicit bounds. Nearby lookup uses an indexed spatial grid. No Entity worker loops over the complete world every frame.

Failed native compensation enters a bounded, deduplicated in-memory cleanup queue. Retry work shares the configured recovery batch bound. A delayed cleanup re-inspects the current native identity before deletion; a recycled handle with a mismatched type/model or available NetID is treated as an unrelated replacement and is not deleted. Pending, resolved and exhausted states are audited and exposed through bounded read-only diagnostics.

Database access uses parameterized Core DataPort calls. SQL and table selectors are not exposed to consumers. A central public-error boundary restricts every contract failure to that exact contract/version's generated error set, maps dependency/capability/idempotency internals to compatible stable codes, removes provider trace IDs and retains only bounded quota scope/limit details. Core attaches the caller-visible trace ID. Native handles, SQL, driver messages and authority tokens are not returned to consumers.

Core event, audit and metric publication is best effort and does not roll back an already committed Entity lifecycle transition. Any unavailable/rejected writer degrades Entity health as `OBSERVABILITY_UNAVAILABLE`; a failed metric write is not cached as a successful local update. This makes evidence loss visible without claiming durable delivery that the current Core surface does not provide.

## Audit surface

Lifecycle evidence uses bounded Core audit records for `created`, `spawned`,
`materialized`, `dematerialized`, `checkpointed`, `owner_changed`,
`binding_changed`, `bucket_changed`, `orphaned`, `recovered`,
`recovery_failed` and `deleted`. Admission and authority failures additionally
record `quota_denied`, `foreign_resource_access` and `stale_entity_access`.
The immediate Core caller remains the actor; failure audits expose only the
contract and structured error code rather than caller-supplied Entity details.

Explicit caller mutations run the documented pre-operation hooks. Mandatory cleanup caused by resource stop, character/group deletion coordination, authority loss or unexpected native removal cannot be vetoed by an extension hook; it remains generation/ownership fenced and attempts the matching bounded lifecycle event/audit publication. Publication failure degrades observability health but cannot revive an already committed transition.

## OneSync and global policy

The resource requires OneSync and applies policy only to managed routing buckets. It does not set global `sv_entityLockdown`, `sv_filterRequestControl` or `sv_stateBagStrictMode`. Read-only diagnostics can report observed values and recommendations; operator configuration remains explicit.

## Control plane

`synex_control` receives only Entity read, query and bucket-read capabilities. Its Entity view can display bounded summaries, exact stable-Entity-ID inspection, managed-bucket metadata/definitions and recovery/authority information. Returned handles and NetIDs remain transient observations. Control has no spawn, move, teleport, delete, component/state write or database capability, and its NUI callbacks are read-only.

## Remaining security acceptance

Static tests and scans are guardrails, not proof of deployment security. Before promotion, the exact candidate needs live adversarial cases for forged/stale EntityRefs, foreign bindings/buckets, source reuse, out-of-band bucket moves, NetID reuse, quota races, resource restarts, state-bag behavior and native/database failure compensation.
