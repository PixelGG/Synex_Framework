# Search and tracing

Global search routes are generated from each authorized provider view's validated `search.kinds` metadata. The browser has no hard-coded domain map and cannot select an undeclared kind, mode, provider, or access class. Exact mode is the default; prefix mode exists only where the provider explicitly declares and bounds it.

Supported routing kinds are:

| Kind | Provider | Modes and current boundary |
| --- | --- | --- |
| `trace` | Core | Exact retained in-process span lookup with bounded keyset pagination, falling back to durable audit correlation when no retained span matches |
| `resource` | Core | Exact or prefix registry lookup |
| `user` | Core | Exact active-session lookup by user ID; the query value and user ID are not returned |
| `session` | Core | Exact active-session lookup is available |
| `character` | Core | Exact character lifecycle lookup is available |
| `contract`, `capability` | Core | Exact or prefix bounded registry lookup |
| `group`, `membership` | Groups | Exact |
| `account`, `transaction` | Accounts | Exact; `financial` access class |
| `entity` | Entities | Exact |

The server verifies the provider/view/kind relationship from trusted metadata. Values, opaque cursor handles, mode, page size, scalar filters and sort shape are validated before invocation. Search has a higher token cost than an overview request and returns bounded results. Any raw provider cursor is retained server-side and represented by a player- and request-scope-bound handle with a 120-second TTL; changing provider, view, query, filters, sort, or limit invalidates reuse. Bucket diagnostics use the bounded Entity bucket list and inspector views rather than the global search surface.

Financial searches require `synex.control.financial`; trace searches require `synex.control.audit`; user search requires `synex.control.identifiers`. The user route returns only bounded active-session projections and never echoes the supplied user ID. Other identifiers remain masked unless the operator also has `synex.control.identifiers`.

## Trace history and limitations

Core retains at most 512 completed in-process spans and exposes them through the audit-protected `tracing` list. Rows contain trace ID, span ID, parent span ID, at most 16 child span IDs, resource, operation, duration, success/error state, bounded error code and timestamp. The `trace_detail` view requires one exact `trace_id` and pages the retained tree. Provider-side positive decimal keysets advance to older spans; the browser sees only the scoped opaque Control handle.

Exact global trace search checks the retained span history first. If it has no match, Core uses its bounded durable audit-correlation lookup; the result states which source answered. No arguments or payloads are stored. History resets with Core and is neither durable nor distributed, so cross-process waterfalls and complete cross-domain causality remain unavailable.

The separate RPC/hook diagnostic views expose registered owner plus process-local call, success, failure, timeout and hook-policy-denial counters, registration-scoped average/last/maximum latency, and p50/p95/p99 from at most 64 recent duration samples. Raw invocations and durable latency series remain unavailable.

The `slow_queries` view separately pages at most 128 process-local aggregates for operations that crossed the configured database warning threshold. It reports attribution, operation kind, a statement hash, last/maximum duration, occurrence count, outcome, timestamps and an available trace ID; it never stores or returns SQL text or parameters. Public oxmysql does not expose a pool snapshot, so pool telemetry remains explicitly unavailable. Control never substitutes example timing rows and never searches by arbitrary SQL or browser-supplied field names.
