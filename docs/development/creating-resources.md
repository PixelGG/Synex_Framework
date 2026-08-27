# Creating a Synex resource

> [!IMPORTANT]
> This guide targets the experimental post-Core resource model. Newly created resources, the current example, generated SDK integrations, and every existing non-Core module are outside `synex_core` Production-Beta certification and require their own design, security review, runtime acceptance, and release decision.

The CLI can create the minimum server-only structure:

```bash
node --experimental-strip-types tools/cli/src/bin.ts create resource synex_example_two
```

The command refuses an existing destination and keeps paths inside the selected repository root. Review the generated files before adding behavior.

## Required boundaries

Every runnable Synex resource has:

- an `fxmanifest.lua` with `fx_version 'cerulean'`, the `synex_manifest` metadata entry, and real file references;
- a schema-versioned `synex.resource.json`;
- explicit required/optional/development dependencies;
- declared capability requests, provided/consumed contracts, provided/required services, event and hook authority, migrations, and table ownership;
- an explicit `stateSnapshot` declaration with `supported` and schema version `1`, even when support is `false`;
- server/client/NUI files only when those execution sides are needed.

Use `synex_example` only as the smallest source-level provider example. It is not a production-ready template. Do not copy a gameplay scaffold containing only `.gitkeep`; those directories are reserved names, not templates.

## Define a contract

Add a `*.contracts.json` collection that conforms to [`schemas/contract.schema.json`](../../schemas/contract.schema.json). Each operation declares an exact version, provider, kind, stability, network direction, input/output JSON Schemas, bounded errors, and—when needed—a capability, session states, idempotency, and rate policy.

Security-sensitive objects should set `additionalProperties: false`, require every field used for authorization or mutation, and bound strings, arrays, and numbers. Client-provided prices, balances, permissions, identifiers, entity ownership, or timestamps are not authoritative.

Add each provided/consumed name to `synex.resource.json`, then regenerate:

```bash
npm run generate
npm run validate
```

## Acquire the API

```lua
local api, apiError = exports.synex_core:GetAPI('^1.0.0')
if not api then
    error(('Synex unavailable: %s'):format(apiError.code))
end
```

The call must happen directly from the consumer resource. Do not wrap `GetAPI` in a shared broker that erases the real principal.

## Register behavior

- Use `api.RPC.registerServer` for local contract calls.
- Use `api.RPC.registerNetwork` only for declared client-to-server operations with explicit session and domain authorization.
- Use `api.Services.provide` for a versioned, local multi-method provider.
- Use `api.Services.setHealth` only for the caller's exact registered service version; Core excludes `UNHEALTHY` providers and providers with an open circuit from dependency resolution.
- Use `api.Events` for notifications that do not require a return.
- Use `api.Hooks` for an ordered return/rejection pipeline.
- Use `api.Scheduler` instead of an unowned timer so restart cleanup is tracked. Long-running handlers should accept the optional second cancellation-context argument and call `checkpoint()` at safe yield boundaries; cancellation remains cooperative.

Registrations return opaque tokens and are tracked to the current resource epoch. Avoid holding internal objects or exposing convenience exports that substitute the provider as caller for a downstream consumer.

Provider callbacks run across a Cfx resource boundary when Core invokes them. Keep `value, nil` for success, but return `false, error` for failure so the error survives Cfx's positional result transport. If a resource introduces its own provider-side SDK adapter, that adapter may convert local `nil, error` results to `false, error` at the boundary; no such adapter is included in the repository today. Consumers of raw Core exports and facade calls must likewise use the second return slot as the authoritative error signal.

Every event topic and hook name must also be declared in `synex.resource.json`. `events.publish` and `events.subscribe` control event production and consumption; `hooks.register` and `hooks.run` control hook providers and callers. Declarations are exact names or a terminal segment wildcard such as `synex.accounts.*`. A non-Core resource may publish events and run hooks only in the namespace derived from its resource name (`synex_accounts` owns `synex.accounts.*`); subscribing to or extending another domain is possible only through an explicit reviewed declaration. A foreign-domain hook declaration permits only an optional observer or patch provider: only Core or the hook namespace owner may register `required = true` or return `deny`. Do not grant a third-party resource critical hook policy authority until a separate centrally managed trust policy exists. Hook input, closed `{ timeoutMs, traceId, metadata }` context, every provider result, and the final candidate are structurally and byte bounded; Core derives the cooperative monotonic deadline. The runtime rechecks the current declaration during delivery, fences registrations to the owner epoch, and caps both event and hook registrations at 256 per resource. Empty arrays are required when a resource uses neither primitive.

Resources that own character-scoped state can register through `api.Characters.registerLifecycleParticipant`. Supply a bounded `timeoutMs` only when the default 5 seconds is unsuitable (`100..30000` ms), keep every callback idempotent, and treat the deadline as cooperative because Core observes an overrun only after Lua returns. Required participants must finish activation in `prepare` and must define `rollback` to release prepared runtime state; Core rejects `commit` on required participants so critical work cannot run after the session is persisted as `ACTIVE`. Use `commit` only with `required = false` for a best-effort post-activation notification. Mark a participant optional only when loading or deleting a character remains correct without its preflight result; required prepare/preflight failures stop the transition. Unload cleanup is fail-closed: while exact caller authority remains current, Core continues later callbacks and finishes unbinding even if one required callback fails, and never restores a partially unloaded session to `ACTIVE`.

Do not bypass `SESSION_PERSISTENCE_PENDING`. It indicates that Core has unloaded local character authority but has not yet confirmed the optimistic session write; create, select, and delete remain blocked until the bounded reconciliation worker confirms persistence.

## Request capabilities

Adding a manifest declaration records intent; it does not grant access. The operator separately grants the exact capability in `core/synex_core/config/capabilities.json`. Keep requests minimal and never request wildcards simply for convenience.

A resource that provides Groups extension definitions must request both `synex.groups.registries.manage` and the exact registration capability it consumes. On every resource start it calls `synex.groups.registries.begin` with one start-scoped idempotency key before registering the complete desired group-type, relation-type, duty-state, or attribute-schema set. A restart uses a new begin key; stale owner epochs fail closed. See [Custom group types and definitions](../groups/custom-group-types.md#owner-bound-group-types).

## Expose optional Control diagnostics

When a resource owns a diagnostic read model, it may declare one `controlProvider` in `synex.resource.json` and request `synex.control.provider.register`. The resource depends on Core, never on the optional `synex_control` NUI.

The descriptor declares a unique namespace, bounded label/category/version, a subset of the fixed read-operation allowlist, and one through 32 fixed presentation views. Every view has an access class; declare closed bounded input fields when it needs operator values, and declare kinds, modes, and a per-kind access class for every search view. Runtime registration through `api.ControlProviders.register` must match the descriptor exactly. Keep `summary` compact; use stable cursor/keyset pages and server-side filter/sort allowlists for larger read models. Control keeps provider cursors behind scoped opaque browser handles. A registration failure leaves diagnostics unavailable but must not stop the owning domain or create a broad fallback service.

Provider handlers receive a defensive request and a read-only context with `deadlineAt`. Return only bounded JSON projections and public errors: no secrets, SQL, paths, stack traces, raw registries, database adapters, callables or mutation methods. `simulate` may explain an existing policy decision but cannot persist it. Control applies another sanitizer before NUI transport, but the provider remains responsible for least-data projection.

See [Control provider contract](../control/providers.md) and [Extending Control](../control/extending-control.md). Static validation and certification check declarations and dependency direction; runtime timeout, owner-restart, output-bound, redaction and real CEF behavior require separate tests.

## Own persistence

Place forward-only SQL in the resource's `migrations/` directory and declare every file and owned table in the resource manifest. Reviewed server domains use the caller-bound `api.Database` DataPort instead of declaring a direct oxmysql dependency. Request and receive only the operations needed (`read`, `write`, `transaction`, or `maintenance`); Core validates the current owner epoch, positional parameters, statement shape, limits, and every referenced table against `dataOwnership.tables`.

Use `transaction` for an externally initiated atomic mutation with a bounded operation name, idempotency key, canonical request object, and handler. Use `maintenance` only for bounded reconciliation or worker batches that already have domain-owned retry authority. Do not write another resource's tables; cross-domain changes use contracts, idempotency, durable events, a saga, or an explicitly registered `api.DomainDeletions` provider.

DataPort claims the exact receipt key before a transaction handler runs, but different keys may run concurrently. Global and owner receipt-capacity rows are locked only after the handler returns and its response validates. Treat the receipt as replay protection, not as a domain mutex: lock conflicting rows in a deterministic order and/or use compare-and-swap versions. Because a deadlock, validation failure, or capacity failure can roll the transaction back, the handler must not perform irreversible external effects.

A domain-deletion provider must keep `preflight` and `execute` bounded and make `execute` idempotent. Do not replace a registered schema version while pending actions still depend on it; Core rejects that upgrade, and it rechecks the provider schema under the catalog lock before persisting a new plan. Terminal plan replay is retained for 30 days, not forever, and every plan state counts against the Core limits until physical purge.

Follow [Migrations](../migrations.md) before changing schema.

## Validate and test

```bash
npm run check
npm test
npm run security
node --experimental-strip-types tools/cli/src/bin.ts certify resource path/to/synex_resource
```

Add deterministic unit tests, malformed-input cases, capability denial, restart cleanup, source-generation reuse where relevant, and live database integration for persistence. For NUI, verify transparent/non-interactive closed state, focus release, reconnect, and resource stop.

The static analyzer and certification command find review candidates; neither replaces a manual threat-model and runtime review.
