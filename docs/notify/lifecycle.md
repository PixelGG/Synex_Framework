# Notification lifecycle

A notification is an ephemeral, owner-bound state machine. Callers mutate it
through a handle; they do not replace the identity with a sequence of unrelated
toasts.

```text
CREATED -> QUEUED <-> VISIBLE -> DISMISSING -> DISMISSED
                 |         \-> DORMANT (server presentation only) -> QUEUED
                 \-> SUPPRESSED
       \-> CANCELLED | EXPIRED | OWNER_STOPPED
```

## States

| State | Meaning |
| --- | --- |
| `CREATED` | The request passed canonical validation and received an identity. |
| `QUEUED` | It is admitted but not in the current visible stack. |
| `VISIBLE` | The current revision is projected to the Signal Surface. |
| `DISMISSING` | Removal has begun; no new presentation lifetime is admitted. |
| `DORMANT` | A server-originated visible window ended, but bounded authority metadata remains updateable until hard expiry. |
| `DISMISSED` | Explicit normal removal completed. |
| `SUPPRESSED` | Policy or dedupe intentionally produced no new surface. |
| `CANCELLED` | The caller or progress lifecycle cancelled the record. |
| `EXPIRED` | Its duration or absolute lifetime bound elapsed. |
| `OWNER_STOPPED` | The exact owner epoch ended and cleanup removed it. |

Terminal records leave the client record registry and invalidate their actions.
`DORMANT` is deliberately not terminal: it has no UI projection, actions,
dedupe/group index, or queue slot, but can be revived by a newer full server
update while its hard lifetime remains valid. Under client pressure, dormant
state can be replaced by one of at most 512 lightweight server tombstones that
keeps only the source revision/owner/lifetime fence. A bounded history projection
may retain a redacted lifecycle entry unless the payload sets `history = false`;
that history is a UX/diagnostic convenience, not domain truth.

## Handles and revisions

Creation returns:

```lua
{
    notificationId = '...',
    ownerResource = 'synex_vehicles',
    ownerEpoch = 12,
    revision = 1,
}
```

Every successful mutation returns a new handle with a larger `revision`. Pass
that returned handle to the next operation. Reusing an older revision fails
with `NOTIFY_NOTIFICATION_STALE`; an update that arrives after a newer client
revision is ignored. A handle from a stopped/restarted owner epoch fails with
`NOTIFY_OWNER_STALE` even if the resource has the same name.

```lua
local nextHandle, updateError = handle:update({
    message = 'Finalizing purchase…',
})
if updateError then return nil, updateError end
handle = nextHandle
```

The identity and revision protect ordering, not durability. Handles do not
survive a Notify restart.

## Duration and absolute expiry

`durationMs` controls normal presentation time. When omitted for a toast,
status, or banner, Notify deterministically calculates and clamps a reading
duration:

```text
2,800 ms + (32 ms * Unicode characters in title + message)
+ priority bonus + kind bonus
```

Priority bonuses are low `0`, normal `500`, high `1,500`, and critical `2,500`
ms. Kind bonuses are toast `0`, status `1,000`, and banner `2,500` ms. The final
duration is clamped to 1,500-30,000 ms; an explicit duration uses the same
bounds.

`maxLifetimeMs` is the hard upper bound from creation and cannot be moved by
replacement, refreshes, or updates. Persistent and running progress signals
still have an absolute bound; use a domain UI or durable state when information
must remain available beyond that bound.

An ordinary update, including a changed `durationMs`, remains anchored to the
original visible start. A dedupe `replace` changes presentation content without
renewing time. Only the explicit `refresh` dedupe policy renews reading time,
and only within its refresh-count and hard-lifetime bounds. Terminal progress
is the other deliberate transition that starts a fresh four-second terminal
presentation.

If safe viewport, UI scale, or density lowers the adaptive visible capacity, a
lower-priority visible record returns to `QUEUED` and its normal presentation
deadline is cleared. Promotion after capacity returns starts a new visible
duration, still capped by the original immutable `maxLifetimeMs`; adaptive
layout therefore cannot extend the record's absolute life.

When the visible duration ends, a local record expires and the client promotes
the next admitted entry. A server-originated record becomes dormant as described
above; its actions are removed immediately. The server retains the corresponding
handle record, marks its presentation inactive, and keeps it until hard expiry
or oldest-inactive pressure eviction. A later monotonic full update can revive
that retained record and its client presentation. When the absolute bound ends,
all remaining record/tombstone state and action tokens are discarded even if the
notification was never visible.

## Owner cleanup

Each notification belongs to exactly one resource and one owner epoch.

- Client `onClientResourceStop` removes local records for that epoch.
- Core/Cfx server lifecycle cleanup removes server records, handler references,
  action tokens, and matching pending work for the stopped epoch, then queues a
  bounded owner-stop command and opaque wake for affected clients.
- A restarted resource receives a new facade/epoch; its old handle cannot touch
  the new instance.
- `playerDropped` removes records targeting that source/session.

Client-local and server-delivered owner epochs are tracked in separate authority
namespaces so one side cannot accidentally invalidate the other. Within each
namespace, a newer epoch cleans only the older incarnation; a late older epoch
or stop command is rejected/limited to its exact maximum epoch and cannot reset
the newer incarnation's records or budgets. Server targets and action tokens are
additionally fenced by the exact Core `{source, sessionId, sourceGeneration}`;
numeric source reuse cannot revive an old delivery.

Server commands are hydrated through a serial client pull queue. This preserves
their admitted order, including owner-stop relative to earlier updates, and
prevents concurrent wake handling from resurrecting state that a later cleanup
already removed. Expired, replayed, or target-mismatched pending IDs are ignored
without changing the client session fence.

Domains do not need a manual “dismiss everything” stop handler. They should
still dismiss completed work during normal operation so the user gets timely
feedback.

## Notify and UI restarts

A `synex_notify` restart intentionally starts with empty in-memory state. Late
server commands and stale facades are fenced by owner/session/revision data.

A `synex_ui` restart is different: Notify retains its bounded current client
state, marks UI delivery degraded, and resynchronizes current records when the
shared runtime is ready. Action hints and F9/F10 invocation remain disabled until
the restarted browser acknowledges the exact active revisions. No focus lease is
acquired during loss or recovery.

Automated state-machine tests cover deterministic lifecycle and stale-revision
paths. Exact resource-stop ordering, reconnect/source reuse, UI restart, and
visible transition timing still require live FXServer and client acceptance.
