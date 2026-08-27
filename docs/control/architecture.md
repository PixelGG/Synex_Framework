# Control architecture

> [!NOTE]
> This document describes the current source contract. `synex_control` remains Development / Experimental Alpha until the exact FXServer/CEF acceptance is complete.

## Core-owned provider registry

`synex_core` owns the `ControlProviders` registry. The registry exists independently of the optional NUI and binds every active registration to the caller resource and its current owner epoch.

The caller-bound Core facade exposes:

```lua
api.ControlProviders.register(definition)
api.ControlProviders.describe(namespace)
api.ControlProviders.list({ cursor?, limit? })
api.ControlProviders.invoke(namespace, operation, request, options)
```

Access is capability-gated:

- `register` requires `synex.control.provider.register`;
- `describe`, `list` and `invoke` require `synex.control.provider.read`.

Only the following provider operations can be declared:

```text
summary  health  list  inspect  search  metrics  findings  simulate
```

`simulate` is restricted to side-effect-free explanation. Mutation-like operations such as `delete`, `set`, `give`, `spawn`, `kick`, `ban`, `retry`, `repair`, `reconcile` or `migrate` are not valid provider operations.

## Metadata and discovery

Each discovered `synex.resource.json` can declare one `controlProvider`. Core validates and retains its bounded metadata even when that resource has not registered a callable provider. `list()` therefore returns bounded cursor pages containing both:

- active owner-epoch-bound providers with health, circuit and bounded invocation metrics;
- declared but inactive providers marked `UNAVAILABLE` with an open circuit.

Namespaces are unique across discovered manifests. Core accepts at most 64 provider declarations/registrations, at most eight providers per owner and at most 32 views per provider. The current descriptor schema allows only the fixed presentation primitives:

```text
metrics  key-value  table  detail  timeline  graph  findings
```

Provider metadata cannot introduce HTML, scripts, styles, event names or renderer code.

`describe(namespace)` resolves one exact active or declared provider without scanning the entire catalog. Control uses that path for request authorization and invocation routing; catalog navigation itself is paged.

Every view declares one access class (`general`, `audit`, `security`, `financial`, or `identifiers`). Views that need operator input additionally declare closed `input.fields` metadata, while every `search` view declares its supported kinds, modes, and access class. Control uses this trusted metadata to build the form and route authorization; the browser cannot invent a field or lower the required access class.

## Invocation envelope

`invoke()` accepts a bounded plain JSON object and the optional exact options object `{ timeoutMs }`. The default deadline is 500 ms; valid values are 25 through 2,000 ms. `synex_control` currently requests 750 ms.

On success Core returns:

```text
schemaVersion: 1
namespace: <provider namespace>
operation: <declared operation>
resource: <owning resource>
generatedAt: <UTC timestamp>
durationMs: <measured duration>
data: <defensive JSON copy>
```

The request ceiling is 4 KiB. Core validates depth, entry count, key and string limits before invocation, passes a defensive copy and a read-only context containing caller, provider, namespace, operation, trace ID, deadline and mode, then validates and copies the result again. The complete Core response envelope cannot exceed 32 KiB.

## Isolation and failure state

One invocation may be active per provider. Concurrent calls fail as `CONTROL_PROVIDER_BUSY`; they do not create provider fan-out. FXServer schedules a provider read in an isolated coroutine and returns `PROVIDER_TIMEOUT` when a yielding read crosses its deadline. The provider stays busy until that coroutine exits and its late result is discarded; non-yielding Lua work must remain bounded because it cannot be forcibly interrupted. Stopping, quiescing or restarting the owner invalidates the old epoch and makes the result stale.

Three consecutive provider failures open its circuit for five seconds. A later call enters half-open state; success closes the circuit. Core records only bounded invocation counters and durations in registry metadata.

Representative registry errors are:

```text
CONTROL_PROVIDER_NOT_FOUND
CONTROL_PROVIDER_OPERATION_UNSUPPORTED
CONTROL_PROVIDER_BUSY
CONTROL_PROVIDER_CIRCUIT_OPEN
PROVIDER_TIMEOUT
INVALID_PROVIDER_RESPONSE
PROVIDER_RESPONSE_TOO_LARGE
PROVIDER_ERROR
STALE_RESOURCE
```

Control maps these to a smaller public NUI error vocabulary and never forwards internal messages or stack traces.

## Game-facing transport

```text
NUI -> client: ready | close | request | reportError
client -> server: synex_control:request | synex_control:closed | synex_control:nui_error
server -> client: synex_control:open | synex_control:response | synex_control:access_revoked | synex_control:invalidate
```

Every data request carries a bounded `requestId`. The game-facing request operation is one of:

```text
overview  providers  section  inspect  search  page
```

These are routes, not provider method names. The server validates the provider and view against trusted registry metadata and resolves the declared operation. Global search maps its kind to a provider on the server.

The closed request envelope contains only:

```text
requestId  operation  provider?  view?  id?  cursor?
limit?     filters?   sort?      query?
```

`filters` is a bounded scalar object, `sort` is exactly `{ field, direction }`, and a search query is the bounded `{ kind, value, mode }` projection accepted by the NUI/client allowlist. Control forwards only the normalized provider request fields `view`, `id`, `cursor`, `limit`, `filters`, `sort` and `query`.

Responses are targeted only to the requesting source. There is no diagnostic broadcast.

Raw provider cursors remain server-side. Before a response crosses the NUI boundary, Control seals `nextCursor` into an opaque handle bound to the requesting player and the exact provider/view/query/filter/sort/limit scope. A handle expires after 120 seconds, cannot be reused under a changed scope, and is removed on close, disconnect, resource transition, or Control stop. At most 64 handles are retained for one player.

## Summary-first and lazy views

Opening Control does not build a complete runtime dump. The browser requests the bounded provider catalog separately from the compact overview, follows opaque catalog pages of at most 12 entries, and retains no more than 64 namespaces. Overview invokes `summary` for at most 12 authorized providers inside a three-second aggregate budget and returns only summary, severity, sampling, and attention projections. Selecting a view triggers one section, page, inspection or search request.

List views use bounded cursor pages. Cursor, filters, sort, page size, provider, view, ID and query are validated before Core invocation. Providers apply their own read-model filter/sort allowlists; Control never reads a large domain dataset for browser-side filtering.

Only overview and provider-catalog results use the permission-projected bounded in-process cache. Provider-catalog entries additionally include the requested cursor and limit in the cache key, so distinct catalog pages cannot alias one another. The final sanitizer still runs for every delivery, including a cache hit. Overview has a five-second TTL, the provider catalog has a 1.5-second TTL, and the LRU cache holds at most 64 entries before evicting its least recently accessed entry. Provider-view sections, inspections, searches and data cursor pages bypass this cache; cursor-paged catalog navigation is the explicit cursor/limit-keyed exception.

A start or stop event for a `synex_` resource clears all cache entries and cursor handles, records a bounded Control transition, and sends `synex_control:invalidate` only to currently open, still-authorized viewers. The browser then refreshes the catalog and active non-cursor view. This is invalidation, not a stream of domain metrics, and the usual server authorization and validation still apply to every follow-up request.

## Failure semantics

Control uses this shared severity vocabulary:

```text
HEALTHY  INFO  WARNING  DEGRADED  ERROR  CRITICAL  UNAVAILABLE
```

A missing read model is explicit `UNAVAILABLE`, not an empty success. Core now has bounded process-local span and slow-operation histories, but still reports unavailable data honestly: neither history is durable or cross-process, neither carries payloads or SQL, and database-pool telemetry is unavailable because the public oxmysql API exposes no pool snapshot.
