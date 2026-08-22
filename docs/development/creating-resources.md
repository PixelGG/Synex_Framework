# Creating a Synex resource

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
- declared capability requests, provided/consumed contracts, provided/required services, migrations, and table ownership;
- an explicit `stateSnapshot` declaration with `supported` and schema version `1`, even when support is `false`;
- server/client/NUI files only when those execution sides are needed.

Use `synex_example` as the smallest working provider. Do not copy a gameplay scaffold containing only `.gitkeep`; those directories are reserved names, not templates.

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
- Use `api.Scheduler` instead of an unowned timer so restart cleanup is automatic.

Registrations return opaque tokens and are tracked to the current resource epoch. Avoid holding internal objects or exposing convenience exports that substitute the provider as caller for a downstream consumer.

Resources that own character-scoped state can register through `api.Characters.registerLifecycleParticipant`. Supply a bounded `timeoutMs` only when the default 5 seconds is unsuitable (`100..30000` ms), keep every callback idempotent, and treat the deadline as cooperative because Core observes an overrun only after Lua returns. Required participants must finish activation in `prepare` and release prepared runtime state in `rollback`; Core rejects `commit` on required participants so critical work cannot run after the session is persisted as `ACTIVE`. Use `commit` only with `required = false` for a best-effort post-activation notification. Mark a participant optional only when loading or deleting a character remains correct without its preflight result; required prepare/preflight failures stop the transition.

Do not bypass `SESSION_PERSISTENCE_PENDING`. It indicates that Core has unloaded local character authority but has not yet confirmed the optimistic session write; create, select, and delete remain blocked until the bounded reconciliation worker confirms persistence.

## Request capabilities

Adding a manifest declaration records intent; it does not grant access. The operator separately grants the exact capability in `core/synex_core/config/capabilities.json`. Keep requests minimal and never request wildcards simply for convenience.

## Own persistence

Place forward-only SQL in the resource's `migrations/` directory and declare every file and owned table in the resource manifest. Use positional `?` parameters for runtime SQL. Do not write another resource's tables; cross-domain changes use contracts, idempotency, outbox events, or a saga.

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
