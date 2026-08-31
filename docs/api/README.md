# Public API

Synex `0.1.0` exposes a deliberately small server-side ABI from `synex_core`:

```lua
local api, err = exports.synex_core:GetAPI('^1.0.0')
local value, invokeError = exports.synex_core:Invoke(name, version, request, options)
local status, statusError = exports.synex_core:GetRuntimeStatus()
```

All three exports capture the immediate calling resource as the principal. Console, client, and indirect calls without an invoking resource fail with `CALLER_REQUIRED`. A caller must have a valid `synex.resource.json`; returned facades are bound to its resource epoch and become stale after a restart.

The internal result convention is `value, nil` or `nil, error`. At a raw cross-resource Cfx boundary, Synex replaces a `nil` slot with `false` only when a later meaningful return must be preserved. A raw failure therefore arrives as `false, error`; `value, nil` success remains effectively `value, nil`; and `value, nil, metadata` crosses as `value, false, metadata`. Check the second slot for a truthy error instead of inferring failure from the first value.

Every public contract in `0.1.0` is marked `experimental`. The API version is `1.0.0`, but that does not make the framework release stable.

The separate [Interact API and contract reference](../interact/api.md) documents the caller-bound `synex_interact` facade, `synex.interact@1` service, and its experimental runtime contracts.

> [!IMPORTANT]
> The frozen Production-Beta profile covers one exact `synex_core` tree only. Its three ABI exports and caller-bound facade remain experimental integration surfaces. The current Core DataPort/domain-deletion additions, the Experimental Alpha `synex_groups` Organizations Engine, the server-only Experimental Alpha `synex_accounts` Financial Engine, and every other downstream provider remain outside that certification.

## Facade groups

The caller-bound facade currently includes:

| Group | Current surface |
| --- | --- |
| `Runtime`, `Metrics`, `Diagnostics` | redacted lifecycle/runtime snapshots, a copied effective retention policy, bounded in-memory metrics, doctor checks |
| `Ids` | bounded opaque ID generation by validated namespace |
| `Players`, `Characters` | public session reads and character list/create/select/unload/delete lifecycle |
| `RPC` | contract invocation and manifest-bound server/network handler registration |
| `Capabilities` | capability delegation checks for reviewed bridge-style resources |
| `Permissions` | persistent role definition, assignment/revocation, and permission checks |
| `Access` | server-only, idempotent ban/allowlist administration and bounded reads |
| `Events`, `Hooks`, `Services` | owner-aware local messaging, hook pipelines, and versioned service providers |
| `States` | schema-validated owned state; replicated global/player projections only |
| `Scheduler` | owner-aware delayed and periodic callbacks with cooperative cancellation |
| `Connections` | bounded custom connection-gate registration |
| `Idempotency`, `Outbox`, `Sagas`, `Audit` | persistence-backed reliability primitives; durable publish, saga, and audit facade operations are capability-gated |
| `Database` | caller-bound, manifest-ownership-checked read/write/transaction/maintenance DataPort for reviewed server domains |
| `DomainDeletions` | owner-aware domain-deletion provider registration and coordinated preflight/execute/reconcile lifecycle |

This table is a navigation aid, not a substitute for a contract. Internal factory objects and mutable registries are not public APIs.

### Domain database access

`api.Database` is a server-only DataPort for reviewed domain resources. It is not a raw oxmysql export. Every call remains bound to the immediate caller and its current resource epoch, requires the matching `synex.database.*` capability, and may reference only tables declared under `dataOwnership.tables` in that caller's validated `synex.resource.json`.

- `read(request)` accepts one bounded parameterized `SELECT` statement and returns a bounded copy of its rows.
- `write(request)` accepts one bounded parameterized `INSERT`, `UPDATE`, or `DELETE` statement and commits it transactionally.
- `transaction(request, handler)` claims and locks the exact owner/operation/idempotency receipt before invoking the bounded transaction adapter. Reusing that key with another request fails closed; an exact completed request is replayed without running the handler again. Different idempotency keys may execute their handlers concurrently. Only after the handler returns and its response passes validation does Core lock the global and owner receipt-capacity rows and finalize the receipt and counters atomically.
- `maintenance(request, handler)` provides the same ownership-checked transaction adapter for bounded reconciliation and worker batches, without claiming public-request idempotency.
- `null()` returns the explicit SQL-`NULL` sentinel used in parameter arrays.

The adapter exposes `query`, `many`, `one`, `affected`, `update`, and `insert` inside a transaction. SQL comments, multiple statements, DDL, schema-qualified identifiers, unowned tables, placeholder mismatches, stale owner epochs, and out-of-bound requests or results are rejected before the domain receives a successful result. The receipt is replay protection, not a mutex for domain entities: handlers must still use deterministic row locks and/or compare-and-swap versions for conflicting state. A handler can be rolled back or retried and must not perform irreversible external effects. Direct `oxmysql` access remains a Core implementation detail.

### Coordinated domain deletion

`api.DomainDeletions` coordinates deletion decisions across current, owner-bound providers. Providers register `preflight` and idempotent `execute` callbacks for a named domain and schema version. Preflight decisions are limited to `allow`, `block`, `delete`, `anonymize`, or `retain`; the resulting provider snapshot and plan are persisted before execution.

Only the resource that owns a domain may create its plans through `plan(request)`. `get(planId)` reads a persisted plan, while `process(planId)` executes pending destructive or anonymizing actions behind a fenced lease. Missing provider rebinds and retryable execution failures keep the plan pending for reconciliation; a blocked plan never executes destructive actions. The caller must declare and be granted `synex.deletions.provider`, `synex.deletions.read`, or `synex.deletions.manage` as appropriate.

The coordinator retains at most 10,000 plans globally and 1,000 for one requester owner. Every plan state consumes capacity until the row is physically purged; pending and executing plans are never selected for automatic purge. Terminal plans retain their idempotent replay result for 30 days, after which a bounded compare-and-swap compactor locks candidates in `plan -> global capacity -> sorted requester-owner capacity` order and removes only rows still due. Once that physical purge succeeds, the old replay record no longer exists and the same idempotency key may create a new plan.

Provider schema changes fail closed while a pending action still requires the previous schema version. Plan persistence locks and rechecks the provider catalog after preflight, so a concurrent re-registration returns `DELETION_PROVIDER_SCHEMA_CHANGED` instead of recording a mixed-schema plan. Provider execution remains idempotent and must reconcile retryable outcomes rather than claiming that an unconfirmed destructive effect completed.

`GetRuntimeStatus()` reports lifecycle availability and player admission separately. During a runtime database outage it can validly return `state = "DEGRADED"`, `operational = true`, and `playerAdmission = false`: Core remains available for bounded diagnostics, but it is not healthy and must not admit a new player. Consumers must not treat `operational` alone, or a separate successful Doctor query, as readiness; only `READY` with `playerAdmission = true` and no health reasons is the healthy admission state. The current `synex.runtime.status@2.0.0` contract includes `playerAdmission`; version `1.0.0` is the legacy shape without that field.

A normally returned database-probe failure can recover automatically only after two consecutive successful probes and successful dependency/instance reconciliation. The five-second watchdog cannot cancel an oxmysql `Await`. If oxmysql `2.14.1` loses the callback for a rejected pool `getConnection()`, Core stays fail-closed even if an independent query later succeeds; no public API may clear that fence or start a recovery loop. Restore and verify MariaDB, then restart the complete FXServer process once. A raw Core or oxmysql-only restart is not supported for this incident.

> [!IMPORTANT]
> The API remains experimental even though the documented Core-only runtime profile reached Production Beta on 2026-08-25. Database-outage/recovery, automated, review, publication, and client join/clean-disconnect/reconnect gates passed for the accepted Core tree. This runtime maturity decision does not make the public contracts stable or place any downstream provider inside the accepted profile.

`Idempotency.run` uses a fail-closed, at-most-once execution claim. Its optional settings object is closed and plain: `lockSeconds` is an integer from 5 through 300, `ttlSeconds` is an integer from `lockSeconds` through 604800, and `maximumRequestBytes` / `maximumResponseBytes` are integers from 1 through 65536. Requests and results must be bounded plain JSON before encoding. A completed record is replayed while its tombstone exists; failed or expired pending executions are never automatically reclaimed. They return `IDEMPOTENCY_FAILED` or `IDEMPOTENCY_INDETERMINATE` and require domain reconciliation. `ttlSeconds` bounds response-retention metadata; it does not make reusing an existing key safe. Core intentionally has no automatic tombstone reaper: deleting an expired completed/failed row would make the key executable again without domain-specific proof that reuse is safe.

`api.Permissions.defineRole(name, permissions, { reason })`, `assign(subject, role, { reason, expiresAt? })`, and `revoke(subject, role, { reason })` require `synex.permissions.manage`; `check(subject, permission, explicitDenies?)` requires `synex.permissions.read`. Mutations are persistent and atomically audited. No permission capability is granted by the committed default policy.

`api.Runtime.getRetentionPolicy()` requires `synex.runtime.read` and returns a defensive copy of the effective `{ audit, financial, workerIntervalMs, batchSize, sessionControlAfterDays }` policy. Reading this policy does not itself archive or delete data; each owning domain remains responsible for implementing its documented retention operation.

Runtime feature switches are fail-closed: disabled durable events reject outbox work, disabled sagas reject saga mutations, and disabled state replication rejects replicated state definitions. See [Configuration](../configuration.md).

`api.States.get`, `set`, and `clear` require `{ sessionId, sourceGeneration }` as their final context argument for every `player`-scoped definition. A numeric Cfx source is not durable identity: Core revalidates the current session and generation before access, after replication, and before accounting finalization. Stale or reused sources fail with `STALE_PLAYER_SESSION`; global, entity, and character scopes do not accept this context as a substitute for their normal subject.

`api.Scheduler.after` and `every` invoke handlers as `handler(token, cancellation)`. Existing one-argument handlers remain compatible. The read-only cancellation context exposes `cancelled`, `reason`, `isCancelled()`, and `checkpoint()`; the checkpoint returns `SCHEDULE_CANCELLED` after explicit cancellation or owner quiesce. Cancellation is cooperative because Cfx cannot preempt a Lua coroutine. Removing a running schedule prevents recurrence but does not claim that its handler stopped: Core retains that handler in the global running/detached accounting until it actually returns, and refuses to dispatch beyond the bounded running-handler capacity.

`api.Characters.registerLifecycleParticipant(definition)` binds a character lifecycle participant to the caller's resource epoch. `prepare` is required; `rollback` is also required when `required` is not `false`, while `unload`, `deletePreflight`, and `deleteCommit` are optional callbacks. `timeoutMs` defaults to `5000` and must be an integer from `100` through `30000`; `required` defaults to `true`. Required participants must complete activation in `prepare`; Core rejects a required participant that defines `commit`, so no critical activation work can be deferred until after the session is persisted as `ACTIVE`. A participant may define `commit` only with `required = false`, where it is an explicitly best-effort post-activation notification whose failure is logged and does not roll back the persisted session. A required failure during load preparation or deletion preflight stops that transition, while an optional failure is logged and skipped. The deadline is cooperative: Cfx Lua cannot forcibly preempt a running callback, so an overrun is detected only after the callback returns. A failed required prepare invokes rollback for that participant and every earlier prepared participant in reverse order. Rollback errors are logged rather than used to claim a rollback that did not happen. A deletion action that includes `deleteCommit` is different: its durable reconciliation remains incomplete and retryable until that callback succeeds, so the callback must be idempotent. The delete service returns `state = "completed"` after full reconciliation or `state = "reconciling"` after the character soft-delete is durable but participant reconciliation remains pending.

An unload persistence failure returns `SESSION_PERSISTENCE_PENDING`. The local session remains fail-closed in `SELECTING_CHARACTER`, character mutations and reuse are blocked, and a bounded Core worker retries the optimistic write only while session version, source, and source generation still match. Missing or superseded runtime sessions are abandoned without replaying a stale write.

Unload cleanup continues remaining callbacks after a participant failure while the exact caller session remains current. Core never restores an already partially unloaded session to `ACTIVE`: it completes the local unbind and fenced durable transition to `SELECTING_CHARACTER`, then returns `CHARACTER_UNLOAD_FAILED` with fail-closed state details. Unload callbacks must therefore be idempotent and must authorize every operation against the current Core session.

## Contract calls

Use a canonical contract definition and the generated descriptor rather than inventing event names. Contract input is validated before the handler and output is validated before return.

```lua
local result, callError = api.RPC.call(
    'synex.groups.get',
    '1.0.0',
    { group_id = groupId },
    { timeoutMs = 3000 }
)

if callError then
    print(callError.code, callError.traceId)
    return
end
```

The stable error envelope is:

```text
code, message, traceId?, retryable, details?
```

Do not branch on human-readable messages. Database internals and raw exceptions are not returned through the public result.

Local calls accept only `timeoutMs`, `traceId`, and `idempotencyKey` options. `timeoutMs` is converted to a monotonic deadline within the configured RPC maximum; caller-supplied player sessions, sources, source generations, or absolute deadlines are rejected rather than forwarded to providers.

## Provider registration

The resource manifest must declare every provided contract and service major. Registration is rejected when it does not.

```lua
local token, registerError = api.RPC.registerServer(contract, function(request, context)
    return { value = request.value }, nil
end)
```

Registered RPC, service, hook, lifecycle, and other provider callbacks execute across a Cfx resource boundary when Core calls them. Return `value, nil` on success and `false, error` on failure. Do not return `nil, error` directly across that boundary: the leading hole can discard the error. A provider-side SDK adapter may perform this conversion, but this repository does not currently ship one.

`registerServer` forces `network = none`. `registerNetwork` creates a client-to-server entry point only for an explicitly declared contract and applies closed-envelope validation, a cycle-safe structural payload walk before encoding, an encoded request-payload bound, a complete serialized response-envelope bound, per-source pending limits, token buckets, session/source-generation checks, contract validation, capability authorization, and response validation. Both transport bounds use `rpc.maximumPayloadBytes`. The handler receives a Core-owned monotonic `deadlineAt` capped by both the RPC timeout and the current local session-authority deadline. Handler errors are copied rather than mutated and cross the boundary only with a plain closed shape and a code listed in that contract's `errors`; every other provider failure is normalized to `INTERNAL_ERROR`.

The current `0.1.0` source catalog contains 204 versioned definitions: seven from Core, one example definition, 71 from Groups, 59 from Accounts, 33 Entity definitions across 32 names, seven from World, six from Notify, 12 from Interact, and eight from Security. Fourteen are `client-to-server`: the read-only Groups self projection, three bounded Notify runtime contracts, nine Interact discovery/lease/session/graph-acknowledgement/metric contracts, and the internal Security Sentinel report. The other 190 definitions declare `network: none`. Every client contract requires an active Core session and matching source generation. Groups derives the character instead of accepting one; Notify accepts only closed notification/command/aggregate-metric shapes; Interact resolves canonical targets and execution policy server-side rather than accepting domain effects; Security's Sentinel accepts only bounded, sequence-, freshness-, challenge-, session-, and generation-fenced weak evidence. Internal transport contracts are not application integration APIs. All Accounts, Entity and World definitions and Security's other seven definitions are server-local.

Client cancellation frames are accepted only for an active session and a request ID of 8–96 characters in the transport's restricted character set. They use a per-source token bucket and can cancel only an active request keyed to that source and its current Synex generation; invalid or excess cancellation traffic is ignored. Cancellation is cooperative and does not make an already committed mutation reversible.

Only use `registerNetwork` when a client genuinely requires the operation. Deadlines and cancellation are cooperative: a network handler must check its context and reacquire the current `{ session, source, generation }` authority after every yield before committing persistent, economic, permission, inventory, or entity state. A network contract still needs domain-specific ownership and authorization inside the handler when those facts can change during a yield.

## Events, hooks, and services

- Events are local framework publications with owner-aware subscriptions and optional priority metadata. Publishers and subscribers must declare the exact topic or a terminal `.*` pattern in their current manifest; non-Core publishers are confined to their resource-owned namespace. Payloads and registrations are bounded before delivery. Durable delivery from a committed domain outbox uses the separate capability-gated `publishOutbox` path.
- Hooks form an ordered local pipeline. Providers and callers require separate current-manifest declarations, non-Core callers are confined to their resource-owned namespace, and every registration is removed with its owner epoch. Input, closed optional `{ timeoutMs, traceId, metadata }` context, every result/patch, and the final value are structurally and byte bounded. Core converts `timeoutMs` into a monotonic cooperative deadline and rejects caller-supplied absolute deadlines. A foreign-domain provider is optional and may observe, allow, or patch; only Core or the hook namespace owner may register a required provider or deny the operation. A stale or newly unauthorized optional provider is skipped; the same condition on an authorized `required` provider fails closed with `REQUIRED_HOOK_FAILED`. Critical third-party hook authority requires a future centrally managed trust policy and is not granted by a resource's own manifest.
- Services are versioned local providers. Consumers request a compatible semantic range and a named method. Method capability maps are enforced by the service registry. Definitions, method counts, requests, optional `{ timeoutMs, traceId, idempotencyKey, metadata }` context, results, and errors are structurally and byte bounded before they cross a resource boundary. `timeoutMs` becomes a Core-owned monotonic cooperative deadline; caller-supplied absolute deadlines are not accepted. Provider failures cross only as a newly allocated, closed Core error, and raw exceptions are neither returned nor logged. Provider registration, health, dependency matching, and cleanup are isolated by service major, so a v1 transition cannot overwrite or remove the same owner's v2 provider. A provider may report only its own exact registered version through `api.Services.setHealth(name, version, status)`, where status is `HEALTHY`, `DEGRADED`, or `UNHEALTHY`.

These primitives do not make a server resource trustworthy or sandbox arbitrary Lua code.

`api.Events.publishOutbox(topic, payload, metadata)` requires `synex.events.durable` and accepts exactly a bounded `eventId` (8-36 characters), `aggregateId`, `schemaVersion`, and optional `traceId` metadata. It marks subscriber context with `durable = true`, `outbox = true`, and the stable event identity; a handler failure, stale subscriber epoch, or revoked subscription authority returns retryable `OUTBOX_DELIVERY_FAILED`. Ordinary `api.Events.publish` rejects durable/outbox identity markers, so callers cannot label an in-memory publication as durable. The domain transaction must append the outbox row before this dispatch path is used, and consumers must deduplicate the at-least-once delivery by `eventId`.

The generic Core outbox persists `producer_resource` with each newly enqueued event. Its dispatcher publishes as that producer under the producer's current owner epoch and manifest authority; it never substitutes `synex_core`. Rows created before owner attribution have `producer_resource = NULL` and fail closed through retry/dead-letter handling instead of gaining Core authority. Terminal rows retain event identity, producer, aggregate metadata, attempts, timestamps, and the last stable error code. A bounded retention worker replaces payload/header JSON with empty objects after the configured published/dead windows, marking `payload_compacted_at`; it never touches pending or publishing rows.

Generic idempotency keeps every terminal key tombstone so the same namespace/key can never execute again. A completed response is replayable only until its bounded TTL expires. The hourly bounded Core compactor then nulls only expired `completed.response_json` values; it never deletes keys, reclaims pending/indeterminate work, or removes the request hash. A later call receives `IDEMPOTENCY_EXPIRED` instead of re-running the handler.

Persisted session-control requests use database-authoritative retained-row capacity. An exact valid pending request remains replayable when a limit is reached; only a new request is denied. Completed and expired requests become deletion-eligible after `sessionControlAfterDays`, but pending requests never do, even when their action deadline has elapsed. The authority worker terminalizes those rows first. Request and authority rows are operationally ephemeral after this grace and must not be used as durable audit history; request IDs are never reused.

Core itself registers `synex.runtime@1`; its `status` and `snapshot` methods accept an empty request and require `synex.runtime.read`. The source tree also contains the following provider declarations in downstream experimental candidates or snapshots. This table is a source catalog only: do not infer release support from a declaration.

| Experimental provider declaration | Methods | Method capability |
| --- | --- | --- |
| `synex.groups@1` | the schema-validated operations in the current Groups contract catalog, with dotted suffixes mapped to underscores | per Groups contract; see [Groups reference](../reference/groups.md) |
| `synex.accounts@1` | all 59 schema-validated Accounts operations, with dotted suffixes mapped to underscores | per Accounts contract; see [Accounts reference](../reference/accounts.md) |
| `synex.accounts@1` | `get_control_summary`, `doctor`, `inspect_transaction`, `inspect_account`, `inspect_outbox` | `synex.accounts.integrity.read` |
| `synex.entities@1` | `getHealth` | `synex.entities.health` |
| `synex.entities@1` | `getControlSummary`, `getDiagnosticSnapshot`, `inspectEntity` | `synex.entities.read` |
| `synex.entities@1` | `queryByBucket`, `queryByOwner`, `queryByResource` | `synex.entities.query` |
| `synex.world@1` | bounded resolve, graph, spatial/context, state/door read, access, bundle and diagnostic methods | per method; see [World API](../world/api.md) |
| `synex.security@1` | `reportSignal`, `registerExpectation`, `revokeExpectation`, `getExpectations`, `getAssessment`, `getCase`, `getHealth`, `getControlSummary`, `listDetectors`, `doctor`, `transitionCase`, `reopenCase` | per method: signal emit, expectation manage, case read, diagnostics read, or `synex.security.enforce` for audited case lifecycle mutation; see [Security overview](../security/README.md) |
| `synex.example@1` | `echo` | none; optional example provider |

Identity, messaging, and state remain facade/contract surfaces in `0.1.0`; manifests do not advertise unregistered services for them. Service methods are local server calls, not client endpoints. The Groups Alpha exposes its 70 server-only operations through both versioned server RPC contracts and its versioned service; both routes preserve the immediate caller, apply the same contract validation, and enforce the method capability. `self.snapshot` is deliberately excluded from the service and exists only as the session-bound network projection. Extension providers must call the server-only `synex.groups.registries.begin` once per owner epoch before registering their complete desired definition set. The Accounts Alpha similarly exposes its 59 server-only operations through versioned RPC contracts and the service with the same validation and per-method capability map. The Security Alpha exposes its seven server-local contracts and twelve bounded service methods through caller-bound capabilities; `transitionCase` and `reopenCase` additionally require `synex.security.enforce`, a current expected revision, a reason, and successful privileged audit intent before mutation. The internal client Sentinel report is deliberately not a service method. These routes do not create additional client endpoints or bypass domain authority, evidence-strength, expectation, rate, session, generation, revision, or audit checks.

The non-Core rows above may change or disappear during rework. A manifest declaration, generated type, test, or checked-in provider implementation is not evidence that the owning resource is deployment-ready.

## Operator command surface

The restricted, console-only `synex` command exposes `overview`, typed read operations for `status`, `doctor`, `resources`, `sessions`, `permissions`, `migrations`, `ledger`, `entities`, and the Accounts operations below, plus the explicit restart and access surfaces documented afterward. Exact Core audit lookup uses:

```text
synex trace <trace|character|transaction|resource> <value> [limit]
```

The optional limit is `1..64`; output is structured JSON. `synex overview` is the bounded human-readable summary for initial runtime verification. `synex_status` and `synex_doctor` remain restricted compatibility aliases. The `ledger` and `entities` commands call their read-only service summaries and return a bounded service error when that optional provider is unavailable.

The exact Accounts command surface in the current Core implementation is:

```text
synex doctor accounts
synex ledger
synex accounts status
synex accounts trace <transaction>
synex accounts inspect <account>
synex accounts outbox [limit]
synex accounts outbox-retry <event-uuid> <idempotency-uuid>
synex accounts reconcile <currency> <idempotency-uuid>
```

`outbox` defaults to 25 and accepts `1..50`. Every command is console-only and registered as a restricted Cfx command. Status, Doctor, trace, inspect, outbox, and ledger are bounded reads. `synex accounts reconcile` is a capability-declared, idempotent financial-integrity mutation that persists a reconciliation run, findings, domain audit, and outbox evidence. `synex accounts outbox-retry` is separately capability-gated and can requeue exactly one eligible dead event while retaining a durable retry request and audit trail. Neither operation repairs balances or rewrites financial history.

Prepared Core restarts use the one-way command below while Core is still running:

```text
synex prepare-restart
```

Only execute the returned `restart synex_core` command after the result reports `state = "prepared"`. The command is omitted from every failed result. `RESTART_DATABASE_DRAIN_TIMEOUT` means an in-flight database operation is still active; resolve that blocker and retry preparation while Core remains loaded. Do not replace the failed workflow with a direct Core-resource restart. See [Operations](../operations.md#resource-restart-boundary-in-010).

Durable access administration is intentionally separate and explicit:

```text
synex ban <id> <userId> <reason>
synex unban <id> <reason>
synex allow <id> <userId> <reason>
synex unallow <id> <reason>
synex access <userId> [limit]
```

Quote a reason containing spaces. These commands are console-only, bounded, and audited; the first four mutate Core-owned access records. `synex access` is read-only and accepts a limit of `1..64`.

Resource integrations use `api.Access` instead of console commands. `ban` and `allow` accept `{ idempotencyKey, id, userId, reason, expiresAt? }`; `unban` and `revokeAllowlist` accept `{ idempotencyKey, id, reason }`; `list` accepts `{ userId, limit? }`. Mutation methods require `synex.access.manage`, listing requires `synex.access.read`, and neither capability is granted by default. Expiry uses `YYYY-MM-DD HH:MM:SS`. The current public surface is server-only and user-ID scoped.

## Canonical reference and generation

Contract collections live beside their owning resources. Generate all managed outputs with:

```bash
npm run generate
```

CI uses `npm run generate:check` and fails on drift. Generated artifacts include runtime JSON, Lua registries, the core Lua registry, TypeScript types, and the [generated contract catalog](../../packages/contracts/generated/docs/contracts.md). Generated files must not be edited by hand.

See [Contracts and API stability](../architecture/contracts.md), [SDKs](../reference/sdks.md), the runnable [`synex_example`](../../examples/synex_example/), and the documentation-only [server Accounts consumer example](../../examples/synex_accounts-server.md).
