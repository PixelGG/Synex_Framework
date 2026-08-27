# Control performance and limits

Control is designed around bounded work rather than browser-side filtering.

| Boundary | Current limit/model |
| --- | --- |
| Request body | 4 KiB encoded maximum |
| Response body | 32 KiB encoded maximum |
| Default page | 25 entries |
| Transport page ceiling | 100 entries; a provider can enforce a lower per-view maximum |
| Browser cursor | Opaque player/scope-bound handle, 256 bytes maximum, 120-second TTL |
| Cursor retention | At most 64 handles per player; cleared on close, drop, resource transition, and Control stop |
| Filters | 8 bounded scalar fields |
| Provider call | 750 ms requested deadline, Core maximum 2 seconds |
| Concurrent provider work | One active invocation per provider |
| Concurrent player work | Two active Control requests |
| Overview | At most 12 sampled summaries inside a three-second aggregate budget |
| Provider metadata | 12 providers per catalog page, at most 64 collected namespaces |
| Cache | 64-entry permission-specific LRU cache; five-second overview and 1.5-second cursor/limit-specific provider-catalog TTLs; sections are not cached |
| Core trace history | At most 512 completed in-process spans; pages of 1 through 50; no arguments or payloads; restart-empty |
| Core slow-operation history | At most 128 aggregates above the configured warning threshold; pages of 1 through 50; no SQL or parameters; restart-empty |
| Core Session page | Ascending Session-ID keyset over the active index; default 25, maximum 50; no full registry snapshot |
| Character domain aggregates | Three isolated provider calls, at most 125 ms each with outer-deadline reserve; Core retains count/status only |
| Core runtime outbox | At most 10 newest delivery-metadata rows plus bounded state aggregates; no payloads or headers |
| Core security history | Default 512 process-local entries, hard-clamped 32 through 2,048; newest-first keyset pages of at most 50; restart-empty |
| Server rate limit | Eight-token burst, two tokens per second refill; weighted request cost 1 through 3, with search and inspect currently costing two |

The provider registry validates requests and responses independently of the NUI limits. A busy, timed-out, oversized, restarted, or circuit-open provider fails in isolation.

On FXServer, Core schedules provider reads in an isolated coroutine and returns `PROVIDER_TIMEOUT` when a yielding handler crosses the 750 ms deadline. The timed-out provider remains busy until its late coroutine exits, so it cannot fan out concurrent work; other providers remain available. Lua code that never yields cannot be forcibly interrupted, so providers must still keep synchronous work bounded and observe `context.deadlineAt`.

The UI creates no closed-state polling or animation. While open, overview refreshes every 10 seconds and the selected non-cursor view every 30 seconds; timers stop while the document is hidden or Control is closed. A paginated page is not automatically refreshed because its opaque cursor represents one exact server-side request scope. Cursor pagination is the primary large-data strategy; there is no requirement to materialize a 10,000-row table before rendering page one.

When a `synex_` resource starts or stops, Control invalidates its overview/catalog cache and every cursor handle, then sends a bounded refresh hint to open authorized viewers. Follow-up reads still pass normal rate, schema, ACE, and provider deadlines; invalidation is not continuous polling or metric streaming.

Headless scale fixtures stream logical catalogs of 10,000 Groups, 100,000 Accounts, 20,000 Entities and 1,000,000 Transactions, then exercise first, next, final and invalid keyset pages through the real provider modules. The fixture asserts that no provider materializes more than 26 rows for a 25-row page; it does not allocate or query a complete production dataset. A separate local Node projection harness runs bounded overview, summary, search, inspector and trace rendering with a generous catastrophic-regression guard. These checks do not measure MariaDB, FXServer, Cfx networking, CEF or production concurrency and are not throughput or capacity claims.

Real FXServer/CEF CPU, memory, resize, keyboard, focus and resource-restart measurements remain part of the pending client acceptance.
