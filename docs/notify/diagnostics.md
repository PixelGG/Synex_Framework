# Diagnostics and operations

Notify exposes bounded operational state through the `synex.notify@1` service,
the direct server facade, Core Control provider views, Core metrics, and safe CLI
summaries. These are current-process observations, not delivery receipts or a
durable audit log.

## Health model

The service is registered through required `synex_core`. During binding it is
fenced unhealthy until contracts, Control, workers, and optional compatibility
registration are ready. Runtime health is then:

| State | Meaning |
| --- | --- |
| `HEALTHY` / Doctor `READY` | no current bounded-runtime findings |
| `DEGRADED` | Doctor has a finding, the expiry worker failed, or `synex_ui` is unavailable |
| unavailable | Core binding/service itself is not available |

Missing optional `synex_ui` produces `UI_RUNTIME_UNAVAILABLE` immediately at
bind, and UI start/stop events update health. The service and ordinary
orchestration remain operational while degraded, but normal/high signals have
no native presentation fallback. Only critical text can use the controlled
action-free native fallback.

At the client boundary, `synex_ui.upsertSignal` returns
`{ generation, signal, delivered }`. `delivered = false` means the validated
signal is retained for later reconciliation but CEF was not ready or the browser
send did not succeed. Notify records a client transport failure, does not record
client display or play sound, and attempts the text-only fallback only for a
critical signal once per content generation. A 1,250 ms deadline also covers a
synchronously accepted send whose exact active-surface ACK never arrives.

## Direct and service reads

The server facade provides capability-gated `getDiagnostics()`:

```lua
local notify, apiError = exports.synex_notify:GetAPI('^1.0.0')
if not notify then return nil, apiError end

local snapshot, diagnosticError = notify.getDiagnostics()
if not snapshot then return nil, diagnosticError end
```

It requires `synex.notify.diagnostics.read` and returns bounded counts, owner
aggregates, budget-bucket count, metrics, and metadata-only history. The service
offers the same operational boundary through:

| Method | Exact request | Result |
| --- | --- | --- |
| `get_control_summary` | `{}` | retained records, pending commands, non-terminal progress, actions, owner count, configured maxima, metrics |
| `doctor` | `{}` or `{ limit = 1..100 }` | `{ status, findings, truncated }` |

The client facade has `getDiagnostics()` for its in-memory queue snapshot:
`active`, `queued`, `visible`, adaptive `visibleCapacity`, `records`, `actionTokens`, bounded
`serverTombstones`, `uiVisibilityConfirmed`, `pendingVisibilityAcks`, history
count, sound-enabled state, client lifecycle metrics, average queue wait, UI
bind/retry state, and effective presentation state. The pending ACK count keeps
the bounded browser poll alive for critical signals even when they expose no
actions. The presentation section reports
quiet/context counts, reservations and position order, plus read-only UI
scale/reduced-motion/reduced-transparency/high-contrast preferences. The same
presentation section is available directly through `getPresentationSnapshot()`.
`getHistory(limit?)` is owner-filtered, newest first, defaults to 32, and accepts
1-128. Client and server histories contain lifecycle metadata, not title or
message text, and are discarded on restart.

## Timing definitions

All timings are current-process, monotonic-duration observations in
milliseconds. An average is zero when it has no samples. They measure specific
software boundaries and must not be presented as browser-paint, frame, or
player-perception latency.

| Observation | Exact measured interval | Explicitly excluded |
| --- | --- | --- |
| Server `averageValidationLatencyMs` / `synex_notify_validation_latency` | entry to return of canonical server payload normalization for each send candidate | capability checks, target resolution, rate admission, event dispatch, client work |
| Client `validationAverageMs` | canonical normalization for a local `show`/`progress` request or an incoming server command and presentation | queue admission, UI calls, browser work |
| Client `queueWaitAverageMs` | `enqueuedAt` until promotion into the client's logical visible set; sampled only on promotion | server transit, UI dispatch, visibility ACK, display duration |
| Server/Control `averageWakeDispatchLatencyMs` / `synex_notify_wake_dispatch_latency` | pending-command admission plus synchronous opaque wake dispatch after the exact session fence is rechecked | Core pull, network arrival, client validation, CEF delivery, browser paint |
| Client `renderDispatchAverageMs` | call into `synex_ui.upsertSignal` until that facade returns accepted/delivered state | later browser visibility ACK, paint, compositor output |
| Client `renderAckAverageMs` | successful UI delivery until Notify receives the exact signal generation/revision in `synex_ui`'s active-surface visibility snapshot | browser paint completion, visual readability, player observation |

The visibility ACK establishes that the browser component reported the exact
surface in its `active` phase. It is stronger than accepting an upsert into the
Lua-side store, but it is still not a Web rendering or human-delivery receipt.
The associated raw client counters are `validation_samples`,
`validation_time_ms`, `render_dispatch_samples`, `render_dispatch_time_ms`,
`render_ack_samples`, and `render_ack_time_ms`.

## Doctor findings

Doctor returns at most 100 findings (50 by default). Current finding rules are:

| Code | Trigger |
| --- | --- |
| `NOTIFICATION_QUEUE_PRESSURE` | retained server delivery registry is at least 80% of 512 records |
| `ACTION_BACKLOG` | action-token registry is at least 80% of 512 tokens |
| `COMMAND_BACKLOG` | pending-command registry is at least 80% of 1,024 entries |
| `EXPIRED_ACTION_TOKEN` | an expired token is awaiting the bounded expiry worker |
| `UI_RUNTIME_UNAVAILABLE` | optional `synex_ui` is not started |
| `OWNER_LEAK` | a retained record belongs to a resource that is no longer active |
| `STALE_NOTIFICATION_TARGET` | a retained record no longer matches an active target session |
| `ORPHAN_PROGRESS_NOTIFICATION` | a non-terminal progress record is older than 60 seconds |
| `NOTIFICATION_PRIORITY_ABUSE` | owner has at least 20 creates and more than 80% are high/critical |
| `NOTIFICATION_SPAM` | owner has at least 100 creates in the retained process activity |
| `NOTIFICATION_RATE_LIMIT_PRESSURE` | owner accumulated at least 20 rate-limit rejections |
| `NOTIFICATION_PAYLOAD_ABUSE` | owner accumulated at least 20 invalid-payload rejections |

All current findings use warning severity. A clean result is `READY`; any
finding makes it `DEGRADED`. The `truncated` flag means the requested result
limit was reached, not that the underlying condition was repaired.

## Control provider

Core registers namespace `notify`, version `1.0.0`, with these read-only views:

| View | Operation | Content |
| --- | --- | --- |
| `overview` | `summary` | ephemeral/persistence state and bounded retained totals |
| `health` | `health` | service state, UI resource state, reasons, finding count |
| `owners` | `list` | per-owner active/activity aggregates |
| `budgets` | `list` | visible, queue, registry, history, action, batch, broadcast bounds |
| `rate_limits` | `list` | configured token bucket capacities/refill rates |
| `activity` | `metrics` | server lifecycle/wake/action counters and the freshness of client-reported presentation aggregates |
| `queue` | `metrics` | retained server presentations, pending-command utilization, and fresh client-reported visible/queued gauges |
| `deduplication` | `metrics` | bounded client-reported deduplication total and aggregate availability |
| `grouping` | `metrics` | bounded client-reported grouping total and aggregate availability |
| `suppression` | `metrics` | bounded client-reported suppression/quiet totals plus server rate/capability denials |
| `progress` | `metrics` | current non-terminal progress count |
| `actions` | `metrics` | token backlog plus invocation, expiry, and replay counts |
| `performance` | `metrics` | measured server dispatch samples plus client-reported render samples, averages, coalescing, and transport failures |
| `findings` | `findings` | bounded Doctor report |
| `policy` | `simulate` | closed-shape canonical validation and normalized policy fields |

Owner and configuration lists accept `limit = 1..100`; cursor, filter, and sort
inputs are not implemented. A clipped list reports both `hasMore = true` and
`truncated = true`. Policy simulation has `sends = false`: it validates one
server-authority payload under the `synex_control` owner and never targets a
player or consumes a delivery slot.

## Metrics

The server metric namespace is low-cardinality and uses no title, message,
target, notification, session, token, or trace labels.

Counter names:

```text
synex_notify_created_total
synex_notify_wake_dispatched_total
synex_notify_rate_limited_total
synex_notify_action_total
synex_notify_action_expired_total
synex_notify_action_replayed_total
synex_notify_owner_cleanup_total
synex_notify_transport_failure_total
synex_notify_payload_rejected_total
synex_notify_capability_denied_total
synex_notify_displayed_total
synex_notify_deduplicated_total
synex_notify_grouped_total
synex_notify_suppressed_total
synex_notify_coalesced_total
```

Capability denials are tracked separately from token-bucket rejections. They do
not contribute to `NOTIFICATION_RATE_LIMIT_PRESSURE` findings.

Gauges are sampled by the server worker every five seconds:

```text
synex_notify_active
synex_notify_pending_commands
synex_notify_progress_active
synex_notify_action_backlog
synex_notify_queue_depth
```

`synex_notify_active` counts all retained server handle records, including
inactive presentations; use the Control queue view to split `activePresentations`
from `dormantRetained`. `synex_notify_pending_commands` is the actual bounded
server transport backlog. Wake latency is observed as
`synex_notify_wake_dispatch_latency`; it does not include redemption through the
Core pull contract or later client/UI work.

The client sends one immediate absolute baseline, then an absolute aggregate
snapshot at the server-confirmed 10-second interval through the internal
`synex.notify.metrics.report@1.0.0` RPC. Until that baseline is acknowledged, its
counter snapshot remains frozen; at most five one-second retries run before the
normal interval resumes. Activity after the frozen snapshot is therefore part of
the first delta instead of disappearing when Core was not yet session-ready. The
server accepts reports only for the exact active Core session and source
generation, calculates bounded monotonic deltas, and treats the first accepted
report of every session/client generation as a baseline.
This prevents reconnects and resource restarts from adding old cumulative values
again. Reports are rate-limited, per-field delta-checked, and contain only fixed
counters plus `visible`, `queued`, and `pendingVisibilityAcks` gauges. They never
contain notification content, owner/player/session identifiers, action tokens,
or trace IDs; none of those values become metric labels.

The resulting label-free Core series are explicitly **client-reported
presentation telemetry**, never delivery receipts or security truth:

```text
synex_notify_queue_wait
synex_notify_render_latency
synex_notify_queue_depth
```

The counter series above are cumulative within the current server process.
`synex_notify_queue_depth` is the sum from reports no older than 30 seconds and
falls to zero when every reporting session is stale or disconnected. Control
returns `aggregation = 'client-reported'`,
`trust = 'presentation-telemetry-only'`, and `available = true` only while at
least one report is fresh. When unavailable, fresh gauges are zero while clearly
identified historical cumulative counters may remain non-zero; consumers must
check `available`, `freshSessions`, `lastReportAgeMs`, and `freshnessMs` before
interpreting current presentation state. The reporting-session registry is
hard-bounded to 512 entries; disconnect cleanup is immediate and stale entries
are deterministically pruned only when bounded admission needs space.

## Tracing and audit

Versioned Notify service and RPC handlers run inside the execution context that
`synex_core` creates for the invocation. An incoming Core trace ID is therefore
retained by the Notify provider span, and nested Core calls inherit that trace
chain. Direct local export calls have no Core invocation envelope; Notify does
not fabricate a trace for them or expose notification content as trace data.

A notification is not an audit record. Ordinary toasts, progress updates,
deduplication, grouping, queue movement, and dismissals are not copied into the
durable Core audit store. Notify appends a bounded audit record only for:

- a broadcast admitted through the privileged broadcast path;
- a single or batched critical delivery; or
- a single or batched delivery using the reserved `SYSTEM` origin.

Batch and broadcast records are aggregate-only. Audit context contains the
delivery scope, kind, origin, priority, and bounded sent/failed/target counts;
it never contains title, message, notification ID, player/session identifier,
action token, or arbitrary metadata. When Core supplied a trace ID, the audit
record keeps it for correlation. Financial, permission, inventory, and other
domain facts must still be audited by their owning domain rather than inferred
from a notification.

## CLI

The safe Core commands are:

```text
synex notify status
synex notify doctor
synex doctor notify
```

They read service summaries only. There is no production CLI command that
spams, broadcasts, or simulates delivery to real players.

## Operational interpretation

- Server `wakeDispatched` means the server admitted the canonical pending
  command and dispatched its opaque wake reference. It does not prove that the
  target redeemed it. Client `displayed` requires `synex_ui` to report
  `delivered = true`. Neither is proof that CEF painted the surface or the
  player read it.
- A successful send can still be deduplicated, grouped, queued, expired, or
  degraded at the target client.
- History is bounded UX/diagnostic metadata, never domain truth.
- Use owning-domain audit records for financial, permission, inventory, or
  administrative facts.
- Confirm UI recovery, focus coexistence, safe zones, gamepad paths, CEF output,
  and performance with a real FXServer/client before release.
