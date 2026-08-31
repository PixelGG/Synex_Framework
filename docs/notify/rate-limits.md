# Rate limits and budgets

Notify combines token buckets, a short burst gate, and hard registry limits.
These controls bound work; deduplication and grouping improve UX but are not the
only flood defense.

## Server send budgets

Every server send atomically checks all applicable buckets before deducting any
token:

| Scope | Capacity | Refill |
| --- | ---: | ---: |
| Global | 64 | 20/second |
| Per owner | 24 | 6/second |
| Toast per owner | 18 | 6/second |
| Progress per owner | 8 | 2/second |
| Persistent per owner | 4 | 0.5/second |
| Banner per owner | 2 | 0.1/second |
| Status per owner | 12 | 4/second |
| High priority per owner | 6 | 1/second |
| Critical priority per owner | 2 | 0.1/second |
| Update/dismiss per owner | 48 | 16/second |

The global and owner buckets are charged the larger of the kind and priority
costs:

| Dimension | Cost |
| --- | ---: |
| toast / status | 1 |
| progress | 2 |
| persistent | 3 |
| banner | 6 |
| low / normal | 1 |
| high | 2 |
| critical | 4 |

The kind-specific bucket always costs one token; high or critical also costs one
token in its dedicated priority bucket. For example, one critical banner costs
six global and owner tokens, one banner token, and one critical token. A failed
atomic check deducts nothing and returns retryable `NOTIFY_RATE_LIMITED`.

Before that debit, Notify performs capacity planning for the record and action
registries and validates the target, owner, payload, capabilities, and any
progress transition. Rejection at one of those gates does not consume
send/update tokens. Expiry compaction may remove already elapsed presentation
state as normal lifecycle maintenance, but planned pressure evictions are
committed only after the budget and identifier preflights succeed.

## Client presentation buckets

| Scope | Capacity | Refill |
| --- | ---: | ---: |
| New presentations per owner | 24 tokens | 6/second |
| New presentations globally | 64 tokens | 20/second |
| Updates/dismissals per owner | 48 tokens | 16/second |
| Action invocation globally | 8 tokens | 2/second |

A new client presentation mirrors the atomic server matrix: it consumes the
larger kind/priority cost from global and owner buckets, one token from its kind
bucket, and one high/critical token when applicable. An update or dismissal uses
only the separate owner-scoped update bucket. Tokens refill from the client's
monotonic clock. All priorities, including separately authorized critical
signals, use these buckets; privilege is not a throttle exemption.

The action bucket is consumed only after the selected action is present,
unexpired, unused, current-revision, and confirmed as actually active by the
browser visibility ACK. Rate rejection returns retryable
`NOTIFY_RATE_LIMITED` and does not grant a second action execution.

## Burst gate

One owner may admit at most eight raw new requests in a one-second burst window.
Requests with an explicit `dedupeKey` or `groupKey` may pass the burst-count gate
because they enter a bounded compaction path, but they still consume the owner
and global token buckets. Critical is not exempt.

Use a real key only when compaction is semantically safe. Adding a random key to
bypass the burst gate defeats both the UX and the protection.

## Other cooldowns

| Behavior | Bound |
| --- | ---: |
| Progress render coalescing | 100 ms |
| Sound interval | at least 1,500 ms |
| Client action command interval | at least 250 ms |
| Action TTL | 1,000–30,000 ms; default 10,000 ms |

Sound is globally disabled by default. The local commands are
`synex-notify-sound on|off|toggle`, `synex-notify-sound volume <0..100>`, and
`synex-notify-sound critical-only on|off|toggle`. These preferences live only
for the current client resource process. Volume zero suppresses output;
critical-only suppresses non-critical audio without promoting or hiding any
notification.

Enabling sound does not bypass the 1,500 ms cooldown, the per-notification
`sound` opt-in, or presentation policy. Grouped/deduped bursts do not produce
one sound per source request. Sound is attempted only after the UI upsert
reports `delivered = true`; accepted-but-store-only or failed transport produces
no sound. The shared UI one-shot maps the configured percentage monotonically
to a bounded Web Audio gain envelope and applies a second bounded 8-per-second
transport window; the Notify cooldown normally limits it much more strictly.
The browser independently enforces the same 50 ms/eight-per-second transport
pressure boundary, a four-voice concurrency ceiling, a 64-message replay
window, the active browser-boot ID, and monotonic Notify owner epochs. Epoch
changes do not reset pressure counters. AudioContext availability, real-client
loudness, and device behavior still require CEF acceptance. Haptics are not
implemented.

The other process-local controls are `synex-notify-position
<auto|top-right|top-left|bottom-right|bottom-left|top-center|bottom-center>`,
`synex-notify-duration-scale <50..200>`, and `synex-notify-history
on|off|toggle`. Scaling never bypasses canonical duration or hard-lifetime
bounds. Disabling history prevents future entries but does not clear entries
already held in the bounded in-memory history.

The configured action TTL is only an upper bound. The effective deadline is
also clipped to the current presentation window and hard lifetime, and the exact
deadline is rejected. A queued action may therefore expire before promotion.

## Capacity budgets

Rate tokens do not reserve memory. Independent hard bounds still apply:

```text
128 client records (queued + visible + dormant)
4 visible records
512 server records / 256 per server owner
512 server action tokens
1,024 pending server commands / 128 per target source, 10-second TTL
64 queued client wake references
128 history entries
32 sendMany targets
256 broadcast targets
```

At client capacity with no dormant record to reclaim, only a strictly higher
raw-priority candidate can evict the oldest queued/visible record in the
lowest-priority class. Otherwise admission returns `NOTIFY_QUEUE_FULL`. The
server rejects record/action capacity before allocating unbounded state.

Client dormant server records are evicted before active queued/visible records.
If no dormant record exists, the raw-priority rule above applies. The server
marks elapsed presentations inactive, retains their revisioned handles to hard
expiry, and under registry pressure evicts the oldest inactive record (same
owner first when its owner bound is full). It never evicts a still-active
presentation solely to admit a new send.

## Core contract enforcement

The direct server facade uses the server budget matrix above, and every delivered
request is admitted again by the target client's owner/global/burst engine. The
canonical Core contracts additionally declare these per-contract rates:

| Contract | Capacity | Refill |
| --- | ---: | ---: |
| `synex.notify.send` | 24 | 6/second |
| `synex.notify.update` | 48 | 16/second |
| `synex.notify.dismiss` | 48 | 16/second |
| `synex.notify.command.pull` | 32 | 16/second |
| `synex.notify.action.invoke` | 8 | 2/second |
| `synex.notify.metrics.report` | 2 | 0.2/second |

`command.pull` is an internal ACTIVE-session transport contract. The client
drains opaque wake references in order, keeps the queue bounded, and retries
transient pull/budget pressure only within the pending command's finite
lifetime. This budget cannot create presentation authority; only a successful
target-fenced pull returns a canonical command.

`metrics.report` is an internal ACTIVE-session telemetry contract. The client
sends an immediate baseline and then follows the server-confirmed 10-second
interval. In addition to Core's token bucket, Notify enforces at least five
seconds between accepted reports for a session, permits at most three client
generation advances per minute, and rejects implausible monotonic counter or
latency deltas. The session registry is capped at 512; fresh entries fail closed
when full and only stale oldest entries are eligible for deterministic pruning.
These bounds limit hostile-client work and counter poisoning; they do not make
the client-reported values authoritative.

`sendMany` and `broadcast` perform bounded individual sends; each target can
succeed or fail independently. Broadcast also requires its dedicated capability
and is capped at 256 current active targets.

## Kind and priority policy

Server kinds and privileged priorities use the explicit buckets and weighted
costs above. Client-local callers cannot request banner, high, or critical, so
their local work uses the client owner/global/burst budgets. Critical remains
capability-gated and rate-limited; it is never unlimited. Control reports the
concrete server rate configuration and hard bounds.

## Handling rejection

`NOTIFY_RATE_LIMITED` is retryable at the infrastructure level, but blindly
retrying the same player-facing message usually creates delayed spam. Prefer:

- suppressing a redundant success;
- updating an existing progress handle;
- using a stable dedupe key;
- grouping a homogeneous burst;
- presenting current state inline;
- retaining retry responsibility in the domain workflow, not Notify.

Diagnostics expose aggregate rate-limit counts and owner activity without title,
message, player, or notification-ID metric labels. Authorization failures are
reported separately as capability denials and do not count as rate-limit
pressure.
