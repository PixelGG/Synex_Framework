# Control diagnostics catalog

Navigation is generated from live, validated provider metadata. A declared view can therefore remain visible as `UNAVAILABLE` when its resource is stopped or its provider could not register. View availability is not a maturity claim for the owning Alpha resource.

## Core (`core`) — 32 views

| Views | Operation | Projection |
| --- | --- | --- |
| `overview` | `summary` | Lifecycle, admission, resource/session aggregates, provider health and bounded attention items |
| `runtime`, `instances` | `inspect` | Runtime/API/cluster/queue/worker projection; runtime includes a ten-item Core outbox delivery snapshot, while current instance state adds persisted start, heartbeat and active-lease fields when the instance manager is available |
| `resources`, `dependencies`, `contracts`, `capabilities`, `services` | `list` | Bounded pages or graphs derived from Core-owned registries |
| `resource`, `dependency_impact`, `contract`, `capability`, `service_detail` | `inspect` | Exact resource, dependency-impact, contract, capability-explain and service projections; capability explain can be narrowed to one declared resource and reports declared, granted, explicit-deny and effective-result state |
| `rpc`, `rpc_detail` | `inspect` | Registered RPC owner plus calls, successes, failures, timeouts and bounded process-local latency summary |
| `hooks`, `hook_detail` | `list`, `inspect` | Registered hook owners plus calls, successes, failures, timeouts and bounded process-local latency summary |
| `database` | `inspect` | Runtime database health, separately observed deadlock/retry counters, a bounded slow-operation page, and explicit query-timeout/pool-snapshot unavailability |
| `slow_queries` | `list` | Cursor-paged, process-local aggregates for database operations at or above the configured warning threshold; statement hash and attribution are shown, never raw SQL or parameters |
| `migrations` | `list` | Cursor-paged resource/migration state, expected and recorded checksums, apply time, duration, attempts, bounded error code and page-local drift findings |
| `sessions` | `list` | Ascending Session-ID keyset pages of active technical authority state, default 25 and maximum 50; the final sanitizer masks identifiers unless the operator has identifier access |
| `session`, `characters`, `character` | `inspect` | Exact Session/Character lifecycle inspection and Character cache state; Character detail adds isolated count-only Groups/Accounts/Entities relation summaries without relation records |
| `audit` | `search` | Provider-declared exact/prefix routes over bounded Core registries, retained spans, or durable audit correlation |
| `tracing` | `list` | Cursor-paged process-local Core spans with parent/child IDs, owner, operation, outcome, error code, duration and timestamp; no arguments or payloads |
| `trace_detail` | `list` | Exact trace-ID timeline with bounded cursor pagination over retained spans |
| `health_timeline`, `incident_window` | `inspect` | Recent Core lifecycle transitions, active reasons and unhealthy workers |
| `performance` | `metrics` | Recorded Core contract/provider/database/hook metrics |
| `security` | `findings` | Deterministic current findings plus cursor-paged process-local authorization/validation rejection history, RBAC snapshot, coverage and bounded security metrics |
| `compatibility` | `inspect` | Bounded Core deprecation projection |

The `instances` inspector is deliberately local-current-instance only. It can merge persisted start, heartbeat and active-lease data for the current instance when the manager read succeeds, but it does not offer exact remote-instance drill-down or cross-instance RPC.

The Core search metadata and current behavior are deliberately explicit:

| Kind | Modes | Current result |
| --- | --- | --- |
| `trace` | exact | Retained in-process spans with bounded keyset pagination; when none match, bounded durable audit correlation |
| `resource` | exact, prefix | Bounded resource-registry projection |
| `user` | exact | Active sessions for the exact user ID; the query value and user ID are not returned |
| `session` | exact | Available exact active-session lookup |
| `character` | exact | Available exact character lifecycle lookup |
| `contract` | exact, prefix | Bounded contract-registry projection |
| `capability` | exact, prefix | Bounded declared-capability projection |

RPC and hook execution state is aggregate-only. For each current handler registration, Core exposes calls, outcomes, hook-policy denials, registration-scoped average/last/maximum duration, and p50/p95/p99 from at most 64 recent duration samples. The data resets with its owning runtime registration and is not a raw call log or durable time series.

Trace history retains at most 512 completed in-process Core spans. Each row contains only trace/span relationships, resource, operation, duration, outcome, bounded error code and timestamp; arguments and payloads are never recorded. The exact `trace_detail` view requires a `trace_id` input and pages that one retained trace. This is not durable or distributed tracing: it resets with Core and cannot correlate work from another process.

Slow-query history retains at most 128 process-local aggregates. It attributes operations through the current Core context, reports the latest and maximum duration, occurrences, outcome, trace ID when available, observation timestamps and a statement hash. It does not expose SQL text or parameters and resets with Core. The database inspector projects classified deadlock occurrences and retries actually performed as separate process-local counters when their metric series have been observed; a terminal deadlock can therefore increase the first without increasing the second. An unseen series is `UNAVAILABLE`, not a synthetic zero. Query-timeout telemetry remains `UNAVAILABLE` / `DATABASE_QUERY_TIMEOUT_TELEMETRY_UNAVAILABLE`: `database.queryWarnMs` is only a slow-operation warning threshold, and the watchdog is a health fence rather than query cancellation. Database pool telemetry likewise remains `UNAVAILABLE` / `DATABASE_POOL_SNAPSHOT_UNAVAILABLE` because the supported public oxmysql surface does not provide a pool snapshot.

The Core Session list is backed by the registry's ordered active-session index rather than a full snapshot. Its safe rows contain Session/User/Character IDs, player source and generation, state/version, instance, pending authority flags, authority deadline and connection time; normal identifier masking still applies at the Control boundary. The Core runtime view also reads up to ten newest outbox delivery records and state aggregates for `pending`, `publishing`, `published`, and `dead`. It reports totals, retries, attempts, ages, backlog and health but never event payloads or headers. Disabled durable events are `DISABLED`; read failures remain `UNAVAILABLE` with their bounded error code.

The exact Character inspector invokes only the registered Groups, Accounts and Entities Control providers, with an isolated maximum of 125 ms per domain and an outer-deadline reserve. Core retains only provider status, exact count, `hasMore`/`truncated`, and `linksExposed=false`; it discards all relation IDs, status, currency, Entity-type and payload detail. A failing or stopped domain is isolated as `UNAVAILABLE`. Provider-owned `character_relations` inspectors return at most eight links: Groups and Entities are `general`, while Accounts remains `financial` and exposes no balances. Core's aggregate count projection does not replace those specialist domain views.

The Security view accepts at most 50 findings. Its first page combines deterministic current findings (aggregated stale-session authority without IDs, slow hooks, and capability preflight) with at least one runtime-history slot when runtime history is non-empty. Numeric keyset continuation pages contain runtime history only, newest first. The process-local ring defaults to 512 retained findings and is hard-clamped to the 32-through-2,048 range; retention/drop metadata is explicit. Runtime rows contain only timestamp, category, severity, code, resource or scope, operation and a bounded summary. Store IDs, request/session/source IDs, traces, payloads, details and secrets are not projected. Current runtime coverage includes capability denial, contract validation, rate-limit rejection, event authorization and hook authorization; foreign-call denials are represented by the applicable event/hook authorization category. `identifiersExposed`, `payloadsExposed` and `crossDomainDataExposed` remain `false`. A missing or throwing diagnostics API marks only `runtimeHistory` and the related coverage unavailable; the current findings and rest of the Security view remain usable. Fuzzing and the static analyzer remain `NOT_RUNTIME` / `REPOSITORY_TEST_GATE`.

Audit correlation pages use a positive decimal keyset cursor and continue with older retained rows (`id < cursor`); Control keeps that provider cursor server-side behind its normal opaque player/scope-bound handle.

The migration view merges the bounded live marker/attempt/fence projection with the discovered migration manifests. Its composite keyset is `resource_name` plus `migration_id`, and a page accepts 1 through 50 rows. The ten columns are resource, migration, expected checksum, recorded checksum, applied time, duration, status, attempts, last error code, and finding. It reports `CHECKSUM_MISMATCH`, `MISSING_MIGRATION`, or `SCHEMA_DRIFT` only inside the explicit `MANIFEST_AND_MIGRATION_MARKERS` scope. Finding counts describe the current page, not an unbounded global scan; `physicalSchemaInspection` is `false`. The view cannot apply, retry, repair or roll back a migration.

Missing telemetry remains honest. Core does not claim raw per-call RPC/hook history, durable or cross-process tracing, raw SQL/parameters, database-pool telemetry, or cross-provider incident causality. Those missing surfaces remain explicit instead of being filled with sample rows or inferred root cause. Control's separate self-provider can group only Control-observed provider health, timeout, and resource-transition events in a process-local temporal window.

The Node CLI accepts a repository-contained operator JSON file through `doctor --bundle --runtime-evidence <file>`. It does not open Control or collect FXServer state itself. Without that option it records `UNAVAILABLE` / `RUNTIME_CONTROL_EVIDENCE_NOT_SUPPLIED`. The complete body, including imported evidence, passes the protection contract documented under [Control security](security.md#support-diagnostic-bundle); the artifact is not an in-game Control export or a runtime acceptance result.

## Groups (`groups`) — 23 views

| Views | Operation |
| --- | --- |
| `overview` | `summary` |
| `health` | `health` |
| `groups`, `memberships`, `hierarchy`, `roles`, `grades`, `capabilities`, `duty`, `assignments`, `delegations`, `relationships`, `policies`, `history` | `list` |
| `group`, `membership`, `relationship`, `capability`, `character_relations` | `inspect` |
| `search` | `search` |
| `drift`, `findings` | `findings` |
| `policy_simulation` | `simulate` |

All results come from Groups-owned read models. Group and membership search are exact. The Group inspector adds real member, on-duty, grade, role and subgroup counts, an integrity summary, and bounded links to related views. The Membership inspector attaches at most eight active roles, duty sessions, assignments and effective received delegations per section, with truncation metadata and a link to its Group. `character_relations` reports the exact organization-link count and at most eight bounded membership links for one Character. Capability inspection and policy simulation run the existing read/evaluation paths with explicitly supplied bounded actor/group inputs; they return an explanation and execute no mutation. Policy simulation is a real metadata-driven `simulate` transport path requiring actor Character ID, Group ID and action, with optional target membership/grade IDs. Views that need a group, actor, membership, relationship, capability, scope, action, or target declare those fields in trusted input metadata.

## Accounts (`accounts`) — 19 views

| Views | Operation |
| --- | --- |
| `overview` | `summary` |
| `health` | `health` |
| `currencies`, `accounts`, `transactions`, `holds`, `access`, `integrity`, `reconciliation`, `outbox` | `list` |
| `ledger`, `economy` | `metrics` |
| `anomalies` | `findings` |
| `account`, `transaction`, `hold`, `outbox_detail`, `character_relations` | `inspect` |
| `search` | `search` |

Every Accounts view and its exact account/transaction search kinds require `synex.control.financial`. The Character-relations inspector reports an exact account-link count and at most eight bounded links without balances. Outbox views expose delivery metadata without event payloads. Reconciliation, repair, retry, posting, transfer, mint, burn and hold mutation are absent.

## Entities (`entities`) — 25 views

| Views | Operation |
| --- | --- |
| `overview` | `summary` |
| `health` | `health` |
| `runtime`, `persistent`, `bindings`, `owners`, `resources`, `buckets`, `components`, `state`, `recovery_log`, `entities`, `bucket_entities` | `list` |
| `cluster_authority`, `quotas` | `summary` |
| `entity`, `binding`, `component`, `recovery`, `bucket`, `character_relations` | `inspect` |
| `search` | `search` |
| `metrics` | `metrics` |
| `drift`, `findings` | `findings` |

Entity search is exact. Entity results use stable Entity IDs and bounded authority read models. An observed Cfx network owner is transport-only; it never grants Synex logical ownership, authorization or mutation authority.

The Character-relations inspector reports an exact persistent-Entity link count and at most eight bounded links. Component payloads and State values are absent.

The Recovery inspector accepts one exact Entity ID and returns its generation, policy and status together with attempt count, circuit state, last failure, next retry, recovery-window start and a bounded recovery timeline. Its page limit is 1 through 25 (default 10). It is observation-only and cannot open, close, retry or reset the circuit.

The `quotas` summary reports current, pending, limit, remaining and utilization values for the global, persistent, Entity-type, resource-owner, logical-owner and routing-bucket scopes. It also projects managed-bucket capacity, bucket player capacity, pending reservations and bounded rate-tracker counts. Resource, logical-owner and bucket collections each expose their total and truncation state and return at most the requested limit (maximum 25); this is a live admission snapshot, not a capacity forecast.

## Compatibility (`compatibility`) — 5 views

When the Experimental Alpha `synex_bridge` provider registers, it contributes `overview`, `health`, `compatibility_matrix`, `legacy_usage`, and `migration_readiness`. The health view reports only the current bridge lifecycle and live-adapter evidence availability. The provider reads bounded bridge-owned runtime projections, has no direct database path, and does not make the bridge depend on Control. A score or readiness finding is shown only when it is derived from recorded compatibility usage; no migration percentage is invented.

## Control (`control`) — 5 views

The Control self-provider exposes `overview`, `health`, `metrics`, `findings`, and `incident_window`. `overview` and `health` both use the same bounded current meta snapshot; the separate overview descriptor gives the global summary route a real provider view instead of an inferred fallback. Its process-local counters include requests/responses/searches, cache hits/misses, NUI error reports, provider failures/timeouts, sanitizer failures, payload bytes/limit events, serialization duration and maximum observed provider duration. The incident window groups up to 100 recent Control-observed provider-health, provider-timeout, and Synex resource-transition events over 60 seconds. Correlation is explicitly temporal-only and never asserts root cause.

These counters reset when `synex_control` restarts. They are not a durable telemetry store or a copy of domain state.
