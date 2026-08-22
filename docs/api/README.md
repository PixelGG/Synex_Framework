# Public API

Synex `0.1.0` exposes a deliberately small server-side ABI from `synex_core`:

```lua
local api, err = exports.synex_core:GetAPI('^1.0.0')
local value, invokeError = exports.synex_core:Invoke(name, version, request, options)
local status, statusError = exports.synex_core:GetRuntimeStatus()
```

All three exports capture the immediate calling resource as the principal. Console, client, and indirect calls without an invoking resource fail with `CALLER_REQUIRED`. A caller must have a valid `synex.resource.json`; returned facades are bound to its resource epoch and become stale after a restart.

Every public contract in `0.1.0` is marked `experimental`. The API version is `1.0.0`, but that does not make the framework release stable.

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
| `Scheduler` | owner-aware delayed and periodic callbacks with cancellation |
| `Connections` | bounded custom connection-gate registration |
| `Idempotency`, `Outbox`, `Sagas`, `Audit` | persistence-backed reliability primitives; durable publish, saga, and audit facade operations are capability-gated |

This table is a navigation aid, not a substitute for a contract. Internal factory objects and mutable registries are not public APIs.

`api.Permissions.defineRole(name, permissions, { reason })`, `assign(subject, role, { reason, expiresAt? })`, and `revoke(subject, role, { reason })` require `synex.permissions.manage`; `check(subject, permission, explicitDenies?)` requires `synex.permissions.read`. Mutations are persistent and atomically audited. No permission capability is granted by the committed default policy.

`api.Runtime.getRetentionPolicy()` requires `synex.runtime.read` and returns a defensive copy of the effective `{ audit, financial, workerIntervalMs, batchSize }` policy. Reading this policy does not itself archive or delete data; each owning domain remains responsible for implementing its documented retention operation.

Runtime feature switches are fail-closed: disabled durable events reject outbox work, disabled sagas reject saga mutations, and disabled state replication rejects replicated state definitions. See [Configuration](../configuration.md).

`api.Characters.registerLifecycleParticipant(definition)` binds a character lifecycle participant to the caller's resource epoch. `prepare` is required; `rollback`, `unload`, `deletePreflight`, and `deleteCommit` are optional callbacks. `timeoutMs` defaults to `5000` and must be an integer from `100` through `30000`; `required` defaults to `true`. Required participants must complete activation in `prepare`; Core rejects a required participant that defines `commit`, so no critical activation work can be deferred until after the session is persisted as `ACTIVE`. A participant may define `commit` only with `required = false`, where it is an explicitly best-effort post-activation notification whose failure is logged and does not roll back the persisted session. A required failure during load preparation or deletion preflight stops that transition, while an optional failure is logged and skipped. The deadline is cooperative: Cfx Lua cannot forcibly preempt a running callback, so an overrun is detected only after the callback returns. Rollback and unload errors are logged rather than used to claim a rollback that did not happen. A deletion action that includes `deleteCommit` is different: its durable reconciliation remains incomplete and retryable until that callback succeeds, so the callback must be idempotent. The delete service returns `state = "completed"` after full reconciliation or `state = "reconciling"` after the character soft-delete is durable but participant reconciliation remains pending.

An unload persistence failure returns `SESSION_PERSISTENCE_PENDING`. The local session remains fail-closed in `SELECTING_CHARACTER`, character mutations and reuse are blocked, and a bounded Core worker retries the optimistic write only while session version, source, and source generation still match. Missing or superseded runtime sessions are abandoned without replaying a stale write.

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

## Provider registration

The resource manifest must declare every provided contract and service major. Registration is rejected when it does not.

```lua
local token, registerError = api.RPC.registerServer(contract, function(request, context)
    return { value = request.value }, nil
end)
```

`registerServer` forces `network = none`. `registerNetwork` creates a client-to-server entry point only for an explicitly declared contract and applies envelope validation, encoded payload bounds, per-source pending limits, token buckets, session/source-generation checks, contract validation, capability authorization, and response validation.

All 45 generated contracts in the current `0.1.0` catalog declare `network: none`, and every current provider registers only server-local handlers. The shared client request transport exists, but this checkout exposes no domain contract through it; a future or third-party provider must make network registration an explicit reviewed choice.

Client cancellation frames are accepted only for an active session and a request ID of 8–96 characters in the transport's restricted character set. They use a per-source token bucket and can cancel only an active request keyed to that source and its current Synex generation; invalid or excess cancellation traffic is ignored. Cancellation is cooperative and does not make an already committed mutation reversible.

Only use `registerNetwork` when a client genuinely requires the operation. A network contract still needs domain-specific ownership and authorization inside the handler when those facts can change during a yield.

## Events, hooks, and services

- Events are local framework publications with owner-aware subscriptions and optional priority metadata. Durable delivery from a committed domain outbox uses the separate capability-gated `publishOutbox` path.
- Hooks form an ordered local pipeline. A hook can transform or reject a value and is removed with its owner epoch.
- Services are versioned local providers. Consumers request a compatible semantic range and a named method. Method capability maps are enforced by the service registry. A provider may report only its own exact registered version through `api.Services.setHealth(name, version, status)`, where status is `HEALTHY`, `DEGRADED`, or `UNHEALTHY`.

These primitives do not make a server resource trustworthy or sandbox arbitrary Lua code.

`api.Events.publishOutbox(topic, payload, metadata)` requires `synex.events.durable` and accepts exactly `eventId`, `aggregateId`, `schemaVersion`, and optional `traceId` metadata. It marks subscriber context with `durable = true`, `outbox = true`, and the stable event identity; any subscriber failure returns a retryable `OUTBOX_DELIVERY_FAILED`. Ordinary `api.Events.publish` rejects durable/outbox identity markers, so callers cannot label an in-memory publication as durable. The domain transaction must append the outbox row before this dispatch path is used, and consumers must deduplicate the at-least-once delivery by `eventId`.

Core itself registers `synex.runtime@1`; its `status` and `snapshot` methods accept an empty request and require `synex.runtime.read`. The runnable resources in this repository also register these manifest-declared providers when they are started:

| Provider | Read-only methods | Method capability |
| --- | --- | --- |
| `synex.groups@1` | `get`, `get_read_model`, `list_subject_memberships`, `check_capability`, `get_control_summary` | `synex.groups.read` |
| `synex.accounts@1` | `get_snapshot`, `list_owner_accounts`, `get_hold` | `synex.accounts.read` |
| `synex.accounts@1` | `get_access` | `synex.accounts.access.read` |
| `synex.accounts@1` | `get_integrity`, `get_control_summary` | `synex.accounts.integrity.read` |
| `synex.entities@1` | `getHealth` | `synex.entities.health` |
| `synex.entities@1` | `getControlSummary` | `synex.entities.read` |
| `synex.example@1` | `echo` | none; optional example provider |

Identity, messaging, and state remain facade/contract surfaces in `0.1.0`; manifests do not advertise unregistered services for them. Service methods are local server calls, not client endpoints. Domain mutations remain versioned RPC contracts so Core preserves the immediate consumer identity and enforces contract and capability policy.

## Operator command surface

The restricted, console-only `synex` command exposes typed read operations for `status`, `doctor`, `resources`, `sessions`, `permissions`, `migrations`, `ledger`, and `entities`. Exact audit lookup uses:

```text
synex trace <trace|character|transaction|resource> <value> [limit]
```

The optional limit is `1..64`; output is structured JSON. `synex_status` and `synex_doctor` remain restricted compatibility aliases. The `ledger` and `entities` commands call their read-only service summaries and return a bounded service error when that optional provider is unavailable.

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

See [Contracts and API stability](../architecture/contracts.md), [SDKs](../reference/sdks.md), and the runnable [`synex_example`](../../examples/synex_example/).
