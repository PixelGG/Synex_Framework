# Developing against `synex_groups`

> [!WARNING]
> This is an Experimental Alpha API. The current uncommitted working tree has repository, live-database, isolated-server, restart, and Doctor evidence, but its manual client self-snapshot smoke, exact committed-revision review, and owner maturity/publication decision remain open. Its contracts may still change.

## Dependency and authority boundary

`synex_groups` has one direct runtime dependency: `synex_core`. It obtains database, identity, permission, lifecycle, hook, event, scheduler, audit, service, RPC, and deletion-coordinator APIs through Core. It does not depend directly on `oxmysql` or another gameplay resource.

A consumer also acquires Core so Core can identify the real calling resource:

```lua
local api, apiError = exports.synex_core:GetAPI('^1.0.0')
if not api then
    error(('Synex unavailable: %s'):format(apiError.code))
end
```

The consumer's `synex.resource.json` declares every consumed contract/service and requested resource capability. Operator policy must separately grant those capabilities; a manifest request is not authorization.

## Core binding and recovery

Groups binds to Core through a generation-fenced, resumable coordinator. A generation is ready only after the deletion provider, character-lifecycle participant, `synex.groups@1` service, all 71 RPC handlers, and all five scheduler workers have registered. The service starts `UNHEALTHY`, and public handlers and workers reject work until that complete readiness barrier is reached.

Registration progress is journaled across retryable attempts. Scheduler registrations use ownership tokens so rollback or cancellation can remove only the worker created by the current attempt; completed registrations are reused instead of duplicated. If a retryable registration error exhausts the immediate attempt budget, Groups schedules a new generation-fenced recovery cycle after five seconds. A non-retryable error is terminal for that generation and leaves the resource fail-closed.

When Core stops, Groups immediately invalidates the generation, current API reference, readiness state, runtime index, and both in-memory caches before any yielding cleanup. Stale callbacks, delayed recovery work, and old worker tokens therefore cannot reopen the boundary or cancel registrations owned by a newer generation. Automated rebind regressions cover Core stop/start and interrupted registration. On 2026-08-25, a live Groups restart advanced its owner epoch, and a Core restart produced the expected dependency stop before `ensure synex_groups` restored both resources to `HEALTHY` with Doctor `PASS`.

For actor-driven mutations:

1. Core verifies the actual calling resource.
2. Groups validates the closed request and runs a read-only persistence preflight that resolves the owning aggregate and proves actor authorization without committing state.
3. `synex_groups` verifies the preflight-approved character references through Core.
4. The bounded pre-mutation hook runs only after that authorization boundary.
5. The authoritative transaction repeats operation-specific lifecycle, ownership, scope, capacity, approval, version, and authorization checks before committing.

Never substitute a player source, client-provided grade, or cached UI state for those checks.

## Contract calls

The catalog contains 71 contracts. Exactly 70 are `network: none` and may be called only from server code. Exactly one, `synex.groups.self.snapshot`, is `network: client-to-server`.

Core accepts the self snapshot only for an `ACTIVE` player session, derives the authoritative character ID from that session, and binds the request to its source generation. Its public input contains only `cursor` and `limit`; `limit` is capped at 8, and undeclared fields such as `actor_character_id` are rejected. Each membership contains at most eight public roles and reports `roles_truncated` when more exist. The contract rate limiter has capacity 4 and refills 1 request per second. No Groups mutation or management read is client-callable.

```lua
local result, callError = api.RPC.call(
    'synex.groups.get',
    '1.0.0',
    { group_id = groupId },
    { timeoutMs = 3000 }
)

if not result then
    return nil, callError
end
```

The self projection is called from client code through Core's authenticated transport:

```lua
local snapshot, snapshotError = exports.synex_core:Call(
    'synex.groups.self.snapshot',
    '1.0.0',
    { limit = 8 },
    { timeoutMs = 3000 }
)

if snapshot == false then
    return nil, snapshotError
end
```

It returns only the session character's memberships, public group/grade/role identities, and own open duty state. It never returns other members, membership attributes, capability traces, stored policies, or audit/history data. Do not build a management UI from this projection.

The [generated contract catalog](../../packages/contracts/generated/docs/contracts.md) is the exact source for input/output schemas, capabilities, errors, idempotency, and versions. Branch on stable fields and error codes, not messages.

## Versioned service

The resource provides `synex.groups@1`. Service method names replace dots after `synex.groups.` with underscores; for example `members.list` becomes `members_list`.

```lua
local result, serviceError = api.Services.call(
    'synex.groups',
    '^1.0.0',
    'members_list',
    {
        group_id = groupId,
        actor_character_id = actorCharacterId,
        limit = 50
    },
    { timeoutMs = 3000 }
)
```

The versioned service exposes only the 70 server-local operations. Those RPC and service calls reach the same schema-validated handlers; `self.snapshot` is intentionally excluded from the service so it cannot bypass Core's network-session context. Cfx provider failures cross the boundary as `false, error`; treat the second return value as authoritative.

Every non-mutating Groups response is encoded and rejected above 30,000 bytes, leaving headroom below Core's 32 KiB RPC/service ceiling. Relationship, duty, and assignment lists accept at most 40 items per page; the self projection accepts at most 8; the remaining list limits are defined by their generated schemas and do not exceed 100. Relationship and assignment detail metadata is bounded to 16 KiB. Handle `READ_MODEL_TOO_LARGE` by narrowing the request or page; do not retry the same oversized read indefinitely.

## Extension-registry startup protocol

An extension owner must call `synex.groups.registries.begin` once on every resource start before any call to `types.register`, `relation_types.register`, `duty_states.register`, or `attributes.register_schema`. This requirement also applies when the owner currently has zero definitions, because beginning the epoch retires omissions from its previously active set.

Use one start-scoped idempotency key for every retry of that begin call and generate a different key after a resource restart. A successful response binds the real Core caller, its current owner epoch, and a monotonically advancing synchronization generation. Registration calls succeed only while that exact session is active. A stale epoch, delayed callback, or prior stop cannot write into or clean up a newer session.

```lua
local sync, syncError = api.RPC.call(
    'synex.groups.registries.begin',
    '1.0.0',
    { idempotency_key = registryStartKey },
    { timeoutMs = 3000 }
)

if not sync then
    return nil, syncError
end

-- Register the complete desired set for this resource epoch only after begin.
```

The consumer manifest and operator policy must grant `synex.groups.registries.manage` for the begin call and the specific capability required by each registration contract. Persisted active entries are hydrated only when their stored owner epoch matches an active synchronization session. On resource stop, Groups first deactivates the exact session and then removes only that stopped epoch from the runtime registries.

## Mutations and concurrency

Public mutation contracts carry an `idempotency_key`. Reusing it with the same canonical request returns the stored result with `replayed = true`; reusing it for different content is rejected. Derive keys from stable workflow command identity instead of generating a new key for each retry.

Version-sensitive changes also require `expected_version`. On `CONCURRENT_MODIFICATION`, read current state and decide again rather than blindly looping.

```lua
local result, changeError = api.RPC.call(
    'synex.groups.members.set_grade',
    '1.0.0',
    {
        idempotency_key = commandId,
        actor_character_id = actorCharacterId,
        membership_id = membershipId,
        grade_id = gradeId,
        expected_version = membershipVersion,
        reason = 'promotion_reviewed'
    },
    { timeoutMs = 3000, traceId = traceId }
)
```

## Events

Mutations that produce a Groups effect write immutable domain history, audit-delivery intent, and an outbox item in the same Core DataPort transaction. A Groups worker registered through Core's scheduler publishes `synex.groups.*` through Core with at-least-once delivery. The bounded operation `traceId` is persisted as the history correlation ID and reused for the domain event; older rows without that correlation safely fall back to their `event_id`. Consumers deduplicate by `event_id`.

Current families cover organization/type and creation requests, deletion lifecycle, membership/invitation/application, grade/role/capability, relationship, duty/assignment, delegation, proposal/policy, attribute schema/value, and static group reconciliation. Subscribe to exact topics declared by the consumer manifest.

An event reports a committed Groups fact; it does not authorize a downstream account, inventory, vehicle, or world mutation. The owning resource revalidates and applies its own idempotent transaction.

## Hooks

Selected mutations run bounded Core hooks before persistence. The current names include:

- `synex.groups.before_group_create`, `.before_group_update`, `.before_group_archive`, and `.before_group_delete`;
- `.before_membership_invite`, `.before_membership_activate`, `.before_membership_visibility_change`, `.before_membership_suspend`, `.before_membership_transition`, and `.before_membership_terminate`;
- `.before_grade_change`, `.before_role_assignment`, and `.before_role_removal`;
- `.before_duty_start` and `.before_duty_end`;
- `.before_relationship_change`, `.before_delegation`, and `.before_policy_change`;
- `.before_proposal_execute` followed by the exact target-operation hook for approved proposals.

Security-sensitive routing fields, actor identity, aggregate identity, lifecycle target, and CAS versions are immutable under ordinary hook patches. Approved proposal and approved group-creation content is fully immutable. Returned content is copied and revalidated before persistence. Core still controls namespace declaration, provider authority, owner epoch, payload bounds, and timeout.

## Persistence boundary

Consumers must not read or mutate `synex_groups` tables. Groups itself reaches MariaDB through Core's bounded Database API/DataPort with positional parameters, statement/result limits, explicit SQL-NULL handling, and transaction/maintenance budgets.

Direct access would bypass resource and actor authorization, policy, lifecycle, hook validation, idempotency, optimistic concurrency, history, outbox, runtime-index invalidation, and deletion coordination. Add a reviewed public contract for a missing use case.

## History, runtime index, definition cache, and Doctor

`synex.groups.history.list` returns authorized newest-first domain history using bounded filters and cursors. `synex.groups.doctor` returns `PASS`, `WARN`, or `FAIL` for a bounded integrity set plus cache, persistent-registry, and runtime-index counters.

Capability sources and stored policy rules use a bounded definitions cache. Entries are keyed by namespace, identity, and the durable group/policy revision; authority evaluation verifies the revision again before it returns. Mutations invalidate affected group definitions, role validity windows are re-evaluated against the current clock on every call, and a resource/Core stop clears the cache. Doctor exposes size, capacity, hit/miss/write, invalidation, eviction, and clear counters under `cache.definitions` without exposing cached authority data.

Doctor checks relational orphans, duplicate active state, expired live authority, hierarchy/reporting cycles, relationship and capability defects, policy and transition-policy integrity, definition drift, workflow state, audit delivery, and stale receipts. It is read-only and never repairs data.

Operators can invoke the Core routing command:

```text
synex doctor groups
```

## Validation workflow

Repository commands defined for this workspace include:

```bash
npm run build
npm run check
npm test
npm run security
npm run benchmark
node --experimental-strip-types tools/cli/src/bin.ts certify resource resources/synex_groups
```

The benchmark command executes real Groups Lua read, capability, runtime-index, and policy modules in an embedded Wasmoon VM with deterministic in-memory adapters. It excludes FXServer, networking, and MariaDB and is useful only for local regression comparison.

Live database tests use the guarded disposable environment in [Testing](../testing.md#live-database-gate). The acceptance state is recorded under [Groups acceptance](overview.md#maturity-and-acceptance). A green repository run alone is regression evidence; every changed revision must repeat its applicable gates before the maturity statement changes.

For the uncommitted working tree, the disposable-MariaDB suite passed 96/96, fresh isolated FXServer boot applied 57/57 Core-plus-Groups migrations, and the Groups/Core restart and Doctor checks passed. No manual FiveM client self-snapshot smoke was run. Results from an earlier, smaller Alpha surface still must not be reused, and changed bytes require new evidence. The resource remains Experimental Alpha until the final committed revision is reviewed and an explicit owner maturity/support/publication decision says otherwise.
