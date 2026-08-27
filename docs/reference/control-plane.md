# Read-only control plane

> [!WARNING]
> `synex_control` is **Development / Experimental Alpha**. The provider registry, transport, sanitizer, NUI and headless checks do not replace the pending acceptance on the exact FXServer, CEF and OneSync candidate. It is not part of the frozen Core Production-Beta profile.

`synex_control` is an optional in-game operations and diagnostics surface. It discovers read-only providers through the Core-owned `ControlProviders` registry, requests one bounded view at a time, sanitizes every response and sends it only to the requesting operator.

It is not a remote administration service and exposes no external HTTP API. It cannot execute SQL, restart resources, run migrations, change configuration, moderate players, mutate groups, post financial transactions, retry an outbox event, reconcile a ledger, or spawn, move or delete Entities.

## Development startup

For an isolated development acceptance, start Core before Control and grant only the base ACE to the test principal:

```cfg
ensure synex_core
ensure synex_control

add_ace group.synex_control_test synex.control.view allow
```

An authorized connected player opens the panel with `/synex-control`. Server-console execution does not open a client NUI. The browser must complete its `ready` callback before Lua grants focus.

Do not treat this example as a production role policy. Specialist views need separate ACEs; see [Control permissions](../control/permissions.md).

## Architecture

```text
synex_groups ----+
synex_accounts --+--> synex_core ControlProviders registry
synex_entities --+              ^
synex_bridge -----+              |
future domains --+              |
                                |
                         synex_control
                       (+ self provider)
                                |
                     sanitized lazy NUI
```

- A provider belongs to the resource whose state it describes.
- A domain or bridge provider requires Core, not Control; stopping `synex_control` does not stop a domain. Control registers only its own process-local health provider.
- Control reads provider metadata and invokes declared read operations. It does not query domain tables or retain a domain-data mirror.
- Declarations for discovered but unavailable resources remain visible as `UNAVAILABLE` metadata.
- Registration is owner-epoch-bound. A provider restart removes stale callable handlers.
- A busy, timed-out, oversized, circuit-open or restarted provider fails in isolation.
- Missing telemetry is `UNAVAILABLE`; no sample metrics, traces, timings or health claims are fabricated.

The detailed contracts are documented under [Control architecture](../control/architecture.md) and [Control providers](../control/providers.md).

## Provider catalog

Provider navigation comes from validated `controlProvider` descriptors. The current source declares these namespaces:

| Namespace | Resource | Operations | Views |
| --- | --- | --- | --- |
| `core` | built into `synex_core` | `summary`, `health`, `list`, `inspect`, `search`, `metrics`, `findings` | 32 views: overview; runtime; resources; dependencies; contracts; capabilities; RPC; hooks; services; database; slow queries; migrations; sessions; characters; audit; tracing; performance; security; compatibility; instances; health timeline; resource, dependency-impact, contract, capability, session, character, RPC, hook and service inspectors; incident window; trace inspector |
| `groups` | `synex_groups` | `summary`, `health`, `list`, `inspect`, `search`, `findings`, `simulate` | 23 views: overview, health, groups, memberships, hierarchy, roles, grades, capabilities, duty, assignments, delegations, relationships, policies, drift, history, group, membership, relationship, capability, search, findings, policy simulation, Character relations |
| `accounts` | `synex_accounts` | `summary`, `health`, `list`, `inspect`, `search`, `metrics`, `findings` | 19 views: overview, health, currencies, accounts, ledger, transactions, holds, access, integrity, reconciliation, anomalies, economy, outbox, account, transaction, hold, outbox detail, search, Character relations |
| `entities` | `synex_entities` | `summary`, `health`, `list`, `inspect`, `search`, `metrics`, `findings` | 25 views: overview, health, runtime, persistent definitions, bindings, logical/resource owners, buckets, components, state metadata, recovery log, cluster authority, drift, quotas, entities, bucket entities, entity/binding/component/recovery/bucket/Character-relation inspectors, search, metrics, findings |
| `control` | `synex_control` | `summary`, `health`, `list`, `metrics`, `findings` | overview, meta health, payload metrics, findings, 60-second temporal-only incident window |
| `compatibility` | `synex_bridge` | `summary`, `health`, `list`, `findings` | overview, health, compatibility matrix, legacy usage, migration readiness |

This table describes implemented descriptors/runtime definitions, not availability in every server process. A domain appears healthy only after its runtime provider registers successfully. `synex_bridge` and its Compatibility provider remain Experimental Alpha; their presence does not promote bridge support.

The Core RPC and hook views expose only the registered handler owner, calls, successes, failures, timeouts, hook-policy denials, registration-scoped average/last/maximum latency and p50/p95/p99 from at most 64 recent duration samples. They do not expose raw invocations, payloads or a durable time series.

Core also exposes up to 512 completed process-local spans through cursor-paged trace history and an exact trace-ID inspector. Rows contain only trace/span relationships, resource, operation, timing, outcome and bounded error code; compatibility spans may additionally contain the bounded provider, consumer resource, and closed legacy-API labels. No arguments or payloads are retained. Exact trace search checks this history before falling back to durable audit correlation. The history resets with Core and is not distributed tracing.

The Core slow-query view retains up to 128 process-local aggregates for database operations at or above the configured warning threshold. It reports attribution, statement hash, durations, occurrences, outcome, timestamps and an available trace ID, never SQL text or parameters. The database inspector reuses a bounded page of that history and separately projects observed classified-deadlock occurrences and retries actually performed. Both counters reset with Core and an unobserved series is explicitly unavailable rather than zero. Query-timeout telemetry is `UNAVAILABLE` / `DATABASE_QUERY_TIMEOUT_TELEMETRY_UNAVAILABLE`; neither the warning threshold nor the database watchdog is presented as a query timeout. Pool telemetry remains `UNAVAILABLE` / `DATABASE_POOL_SNAPSHOT_UNAVAILABLE` because the public oxmysql API has no pool-snapshot contract.

Core Session diagnostics use ascending Session-ID keyset pagination over the active registry index, default 25 and maximum 50. Rows contain bounded technical authority state; the final Control sanitizer masks identifiers unless the operator has `synex.control.identifiers`. Core runtime diagnostics also include at most ten newest outbox delivery-metadata rows plus per-state totals/retries/attempts/ages and backlog health. Payloads and headers are never exposed; disabled durable events are `DISABLED`, and database/read failures remain `UNAVAILABLE`.

The Core instance inspector describes only the current process and its own persisted start, heartbeat and active-lease state when available. Remote-instance detail lookup and cross-instance Control RPC remain unavailable.

The Core migration view is a bounded keyset-paged read model over discovered definitions and live marker/attempt/fence state. Its cursor combines `resource_name` and `migration_id`; page size is 1 through 50. Its ten columns project resource, migration ID, expected/recorded checksum, applied time, duration, status, attempts, bounded error code and finding. `CHECKSUM_MISMATCH`, `MISSING_MIGRATION`, and `SCHEMA_DRIFT` are page-local findings in the explicit `MANIFEST_AND_MIGRATION_MARKERS` scope; `physicalSchemaInspection` is `false`. The view neither executes nor repairs migrations and does not present one page's findings as a global or physical-schema scan.

The Entity quota view is a bounded live admission projection. It reports current and pending use, configured limits, remaining capacity and utilization across global, persistent, type, resource-owner, logical-owner and routing-bucket scopes, plus managed-bucket/player capacity and bounded reservation/rate-tracker counts. Per-resource, per-owner and per-bucket collections are limited to 25 and report their total/truncation state; they are not forecasts.

Every view metadata object has a mandatory access class. Views that require operator values declare closed bounded input fields, and each search view declares its allowed kinds, modes, and per-kind access class. Control derives navigation and forms from that trusted metadata instead of maintaining a hard-coded domain search map.

## Request and response boundary

The browser can request only these transport operations:

```text
overview  providers  section  inspect  search  page
```

Requests use a correlated `requestId` and closed fields for provider, view, ID, cursor, page limit, scalar filters, sort and search query. The server resolves a trusted provider/view pair to one operation declared by provider metadata; the browser cannot choose a Lua function, event, export, SQL statement or arbitrary resource callback.

The browser cursor is not a provider cursor. Control seals every provider `nextCursor` into an opaque handle bound to the player and exact provider/view/ID/query/filter/sort/limit scope. It expires after 120 seconds, is limited to 64 handles per player, and is cleared on close, disconnect, resource transition, or Control stop.

Successful server responses use the bounded envelope:

```text
schemaVersion: 1
requestId: <correlation id>
ok: true
data: <sanitized projection>
meta: { durationMs, generatedAt, readOnly: true }
```

Failures contain only a public code and retryable flag. Provider messages, SQL, stack traces, local paths and payloads are not forwarded.

## Summary-first loading

Opening the NUI requests the provider catalog and compact overview separately. The catalog loads opaque-cursor pages of at most 12 providers and collects no more than 64 namespaces. Overview samples at most 12 provider summaries inside a three-second aggregate budget and marks unsampled or unavailable summaries explicitly; it does not carry the full catalog. A selected section is loaded lazily. Lists default to 25 rows; the transport rejects pages above 100 and each provider may enforce a lower per-view maximum. Search and inspection are never replaced by a complete browser-side dataset.

Only the permission-projected overview and provider catalog are cached: five seconds and 1.5 seconds respectively, in a 64-entry LRU cache. A catalog cache key includes its cursor and limit, so one page cannot satisfy a different page request. Provider-view sections, inspection, search and data cursor pages bypass that cache; cursor-paged catalog navigation is the explicit exception. Starting or stopping a `synex_` resource clears cache/cursors and emits a bounded invalidation hint to open authorized viewers; the resulting catalog and active-view reads are authorized again.

Core currently supports exact active-session, character and user-to-active-session search. The user route never echoes its supplied user ID. Resource, contract and capability search also support bounded prefix mode; exact trace search uses retained spans first and durable audit correlation as its no-span fallback. Groups supports exact group/membership search, Accounts exact account/transaction search, and Entities exact Entity search.

The Groups Group inspector reports member/on-duty/grade/role/subgroup counts, integrity state and bounded related-view links. Its Membership inspector reports bounded active roles, duty, assignments and effective received delegations. The metadata-driven policy-simulation view reaches the real read-only `simulate` operation with bounded actor, Group, action and optional target inputs; it cannot persist a decision. The Entity Recovery inspector uses one exact Entity ID to show its recovery policy/status, attempts, circuit, failure/retry/window state and a bounded history; it cannot mutate recovery state.

The exact Core Character inspector invokes the registered Groups, Accounts and Entities providers only through the Control registry. Each domain receives at most 125 ms with an outer-deadline reserve and fails independently. Core keeps only status, provider, exact count and truncation flags; it discards every returned relation ID and domain detail. The provider-owned `character_relations` views return at most eight bounded links. Groups and Entities use `general`; Accounts remains `financial` and returns no balances.

The security-class Core view combines deterministic current findings with a newest-first process-local rejection history. The first page includes aggregated stale-session authority (from a bounded 512-session scan, without IDs), slow-hook and capability-preflight findings and reserves a Runtime slot when available; numeric keyset continuation pages are Runtime-only. Runtime retention defaults to 512 and is clamped to 32 through 2,048. Rows expose only timestamp, category, severity, code, resource or scope, operation and bounded summary for capability denial, contract validation, rate-limit rejection, event authorization and hook authorization; foreign-call denials use the applicable event/hook authorization category. Payloads, details, traces and request/session/source IDs are absent, and `identifiersExposed`, `payloadsExposed` and `crossDomainDataExposed` remain `false`. Runtime-history failure is isolated as `UNAVAILABLE`; static analysis and fuzzing remain repository-only gates.

## Security and privacy

Every request rechecks the connected player source, base ACE, specialist ACE, schema, byte limits, weighted token bucket and in-flight limit. Accounts routes require `synex.control.financial`; Core tracing and exact trace search require `synex.control.audit`; Core capability/security routes require `synex.control.security`; exact user search requires `synex.control.identifiers`. The shared Core search view resolves the selected kind's access class before invocation. The user route projects bounded active-session state but does not return the input user ID.

The final response passes through a central sanitizer that:

- redacts secret-bearing keys and recognizable credential values;
- masks identifiers unless `synex.control.identifiers` is also granted;
- replaces callables, userdata, unsupported values, cycles and non-finite numbers;
- bounds depth, entries, keys, strings and final encoded size.

The identifier ACE never reveals passwords, API keys, tokens, private keys, webhooks or connection strings. See [Control security](../control/security.md).

The CLI diagnostic-bundle builder applies the same protection contract to its complete artifact body through a separate TypeScript implementation: secret-key and recognizable secret-value redaction, identifier masking, depth 10, 2,048 entries, 512-byte strings, 96-byte keys, and explicit cycle/non-finite replacements. It normalizes unpaired surrogates to well-formed Unicode before applying the UTF-8 byte bounds. Symbol-keyed fields are omitted and counted as replacements; accessors become a safe marker without executing a getter. `doctor --bundle --runtime-evidence <file>` can import a repository-contained operator JSON file and sanitizes it as part of the complete body. The command does not itself open Control or collect FXServer state; absent input is recorded as `UNAVAILABLE` / `RUNTIME_CONTROL_EVIDENCE_NOT_SUPPLIED` rather than inferred. This bundle is a support artifact, not a live Control export or acceptance result.

## Closed NUI invariant

While closed, `html`, `body` and `#root` are transparent and non-interactive, no application surface is mounted, the browser has no refresh timer and Lua holds no NUI focus. Close, ACE revocation, render failure and resource stop clear pending state and release focus. Provider output is rendered with fixed DOM primitives and text nodes, never as provider HTML.

## Current verification boundary

Static validation and certification check descriptor shape, unique namespaces, operation/view consistency, required registration capability and dependency direction. The Control suite covers request validation, sanitization, access boundaries, provider isolation, output bounds and closed-state source behavior.

The exact-candidate gate is still open for:

- real FXServer provider registration and unavailable/restart behavior;
- CEF ready/focus/close and access-revocation behavior;
- keyboard, resize and responsive rendering in the real game client;
- provider timeout, opaque-cursor expiry/scope, invalidation, and large logical dataset behavior on the runtime candidate;
- OneSync-dependent Entity projections;
- final security review and owner maturity decision.

Until those gates pass, Control remains Development / Experimental Alpha even when repository checks are green.

## Further documentation

- [Overview](../control/overview.md)
- [Architecture](../control/architecture.md)
- [Provider contract](../control/providers.md)
- [Diagnostics catalog](../control/diagnostics.md)
- [Permissions](../control/permissions.md)
- [Security](../control/security.md)
- [Search and tracing](../control/search-and-tracing.md)
- [Performance and limits](../control/performance.md)
- [Extending Control](../control/extending-control.md)
