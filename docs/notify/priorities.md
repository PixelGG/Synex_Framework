# Notification priorities

`priority` is scheduling urgency. It is independent of `kind` and `tone`.

| Priority | Intended use |
| --- | --- |
| `low` | Deferrable convenience information. It is the first class suppressed under pressure. |
| `normal` | Default gameplay feedback that would otherwise be missed. |
| `high` | Time-sensitive information with meaningful near-term impact. |
| `critical` | Rare framework/system information that must interrupt quiet presentation policy. |

## Capability boundary

Server resources need normal `synex.notify.send` authority. High and critical
requests add separate gates:

```text
high     -> synex.notify.priority.high
critical -> synex.notify.priority.critical
banner   -> synex.notify.banner
broadcast-> synex.notify.broadcast
SYSTEM   -> synex.notify.system
```

Declaring a capability in `synex.resource.json` records intent; the operator
must grant it separately. A denied privileged priority returns
`NOTIFY_PRIORITY_DENIED`. The engine does not silently treat an unauthorized
resource as a system principal.

`SYSTEM` is output-only in the canonical payload. It can be created only through
the dedicated `sendSystem`/`send_system` paths. `synex_core` is the built-in
framework principal; another server resource must declare and receive the
privileged `synex.notify.system` capability in addition to the normal send,
priority, banner, and broadcast capabilities its operation requires.

Local client notifications are deliberately constrained presentation requests;
they do not grant cross-player or system origin authority.

## Arbitration and fairness

Higher priority may overtake lower priority, but the client scheduler also
considers age and owner fairness. Equal effective score is resolved by the
original sequence and is therefore deterministic and stable.

Age promotion prevents an admitted normal item from waiting forever during a
high-priority stream, while absolute lifetime prevents stale work from surfacing
long after it was useful.

An effective quiet presentation context keeps low/normal work queued. High and
critical remain eligible, but neither bypasses capabilities, token buckets,
burst bounds, queue capacity, or absolute lifetime.

Scheduling score and capacity arbitration are intentionally separate. At the
128-record client bound, an old dormant server record is reclaimed first. If no
dormant record exists, overflow selects the record in the **lowest raw
priority** class and, within that class, the **oldest sequence**. The incoming
candidate can evict it only when the candidate's raw priority is strictly
higher. Age score, remaining lifetime, visibility, tone, and kind do not alter
that active-record choice. Otherwise admission returns retryable
`NOTIFY_QUEUE_FULL`; priority is not an unbounded memory reservation.

## Critical is exceptional

Critical priority:

- uses a separate rate budget even for privileged callers;
- may bypass a quiet UI context;
- is the only class announced through assertive `role=alert` semantics;
- may use the narrow text-only fallback while `synex_ui` is unavailable;
- is visible in aggregate diagnostics and priority-abuse findings.

Do not use critical for ordinary validation failures, missing items, purchase
errors, or routine success. If most messages from one owner are high/critical,
Doctor reports `NOTIFICATION_PRIORITY_ABUSE` after sufficient activity.
