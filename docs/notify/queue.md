# Queue and presentation policy

The client orchestrator owns the viewport queue. The server owns target/session
authority and retains update/action records, but it does not decide what is
currently visible on a particular player's screen.

## Admission pipeline

```text
closed validation
  -> owner/session authority
  -> capability (server)
  -> side-effect-free dedupe/group lookup and capacity preflight
  -> per-owner burst preflight
  -> atomic global + owner + kind/priority token check and debit
  -> commit dedupe/group mutation, burst count, and planned eviction/admission
  -> priority + age + owner-fair scheduling
  -> visible Signal Rail
```

The lookup and capacity phases plan the outcome without mutating a live
representative or consuming rate tokens. Time-driven cleanup of already expired
indexes/presentations may still run as lifecycle maintenance. Capacity, action-
registry, stale-progress, and malformed-request failures therefore do not spend
the send/update budget. Once every preflight succeeds, all applicable token
buckets are checked and debited atomically; a failed bucket check deducts
nothing. Only then does Notify commit the burst counter and the planned
compaction, eviction, or new record.

A real dedupe or group key can exempt a request from the raw eight-request burst
rejection because it has a bounded compaction path, but every successfully
admitted request still consumes the normal global, owner, kind, and applicable
priority budgets.

## Hard bounds

| Bound | Value |
| --- | ---: |
| Client records, queued/visible/dormant combined | 128 |
| Visible records | Adaptive 1-4; hard maximum 4 |
| `synex_ui` retained passive signals | 8, reserved for `synex_notify` |
| Server retained delivery records | 512 globally / 256 per owner |
| Server action tokens | 512 |
| Client tombstones for dormant server records | 512 |
| Bounded client history | 128 |

Notify projects only the records admitted by the current adaptive visible
capacity into `synex_ui`. The capacity is deterministic and conservative: the
safe viewport height, UI scale, compact/comfortable density, narrow-viewport
wrapping allowance, and maximum Signal Surface envelope produce a value from
one through four. Four remains the non-configurable safety maximum. The UI
transport may retain up to eight Notify signals during reconciliation and exit
motion, but raw signal upsert/remove/snapshot access is reserved exclusively for
the `synex_notify` resource. That retention bound does not expand the current
visible presentation capacity.

## Scheduling

Base weights are:

```text
low = 0, normal = 20, high = 40, critical = 60
```

Every four seconds in the queue adds eight age points. A candidate from a
different owner than the last promoted owner gets six points; repeated
consecutive promotions from one owner receive an increasing penalty. The
highest effective score is promoted, with original sequence/FIFO order as the
deterministic tie-breaker.

When viewport or presentation preferences reduce capacity, the engine retains
the highest-priority visible records (newest creation/revision and stable signal
ID break ties) and returns the remainder to the normal queue. Increasing
capacity promotes from that same queue policy. Capacity changes do not create a
second browser-only scheduler.

This lets urgent work overtake normal work while allowing an older normal item
to age into service. Priority still does not guarantee visibility after its
absolute lifetime has expired.

## Overflow

At the 128-record bound, the engine first evicts the oldest dormant server
record, because it has no queue/visible surface or action. If no dormant record
exists, it selects the lowest raw-priority queued/visible record; among equal
priority it selects the oldest sequence. The incoming candidate may evict that
active record only when its raw priority is strictly higher. The removed record
enters bounded history as `EVICTED` with reason `queue_evicted`. Otherwise the
request fails with retryable `NOTIFY_QUEUE_FULL`.

The candidate does not evict an equal-priority item merely because it is newer.
Visible records are part of the same bounded set and can be preempted by a
strictly higher-priority request under full pressure.

The server registry has a different pressure rule because it is an authority
and handle store, not the viewport scheduler. A send first marks elapsed
presentation windows inactive. If the global 512-record or per-owner 256-record
bound is still full, it plans eviction of the oldest inactive retained record
(preferring the same owner when that owner's bound is full). An active
presentation is never evicted merely to admit another send. If no inactive
record can make room, the send fails with `NOTIFY_QUEUE_FULL`. Planned pressure
eviction is committed only after action-capacity, token-budget, and ID
preflights succeed.

## Expiry behavior

`maxLifetimeMs` begins at creation and is an immutable absolute ceiling.
Queued records can expire without ever becoming visible. A normal `durationMs`
starts when the record becomes visible, then is capped by the remaining absolute
lifetime. An ordinary update or dedupe `replace` remains anchored to the
original visible start and cannot renew reading time. Only an admitted
`dedupePolicy = 'refresh'` operation renews the current visible duration, subject
to `maxRefreshCount` and the same absolute ceiling. A terminal progress morph
starts its bounded terminal duration.

Adaptive-capacity demotion pauses the normal visible-duration window by clearing
its presentation deadline before the record re-enters the queue. A later
promotion starts a fresh bounded visible window, but never moves the immutable
`maxLifetimeMs` ceiling; a record can therefore still expire while queued.

Persistent/running progress records omit a normal duration but still expire at
the absolute ceiling. A durable or indefinite condition belongs in a domain UI
or state model.

For a server-originated timed notification, visible expiry makes the client's
surface **dormant** instead of destroying the authoritative server handle. The
client removes it from the queue/rail, clears its actions and compaction indexes,
and retains only bounded dormant metadata until the hard lifetime. If dormant
metadata must be evicted under client pressure, a bounded tombstone preserves
the owner, source revision, creation time, and hard expiry. A later full,
monotonic server update can revive either form through the normal dedupe/group
and capacity policy; a stale update cannot. Tombstones expire at the same hard
deadline and are included in timer scheduling.

The server likewise separates `presenting` records from inactive `retained`
records. Its presentation window is a conservative send-time bound because the
server cannot observe the client's actual queue promotion or browser paint.
Inactive retention exists only for revisioned update/dismiss/owner cleanup and
ends at the hard lifetime or earlier pressure eviction; it is not an offline
inbox or delivery receipt. A valid full update can revive an inactive record
with a new bounded presentation window.

## Presentation context

The client facade accepts at most 16 owner/epoch-bound presentation contexts.
A context can mark a quiet period, reserve canonical positions, or provide a
preferred position and ordered fallbacks. Position arrays are dense, unique,
and contain at most the six canonical positions; contexts never accept pixel
offsets or domain-specific rules.

Effective quiet state is the OR of all active contexts. Low and normal work
remains queued while quiet; high and critical work can still be considered,
subject to every normal capability, token, burst, capacity, and lifetime bound.
When a signal's requested position is reserved, Notify chooses an unreserved
preferred position, then declared fallbacks, then a deterministic canonical
position. If every canonical position is reserved, the requested position is
retained rather than inventing geometry. Context changes re-project visible
signals with newer revisions.

Contexts are removed when their owner stops. They influence presentation only;
they do not determine whether a gameplay operation occurred. Domain resources
should still prefer inline feedback while their UI is open and avoid producing
global signals they already know are redundant.

## UI unavailability

An upsert can be accepted into the bounded `synex_ui` store while returning
`delivered = false` because CEF is not ready or the browser send failed. Notify
counts that result, or a rejected upsert, as a transport failure; it does not
count a client display or play sound. Only an admitted critical signal attempts
the text-only native fallback, once per content generation. It does so after an
immediate delivery failure or when the exact browser-active ACK is still absent
after 1,250 ms. Normal/high gameplay messages do not spill into a fallback feed.
The engine lifecycle and UI-store retention remain bounded so current
snapshots/revisions can be reconciled when the browser returns, without focus
acquisition. Store retention is not proof of browser paint. Notification actions
remain fail-closed until the browser has acknowledged the exact active surfaces;
see [Actions](actions.md).

## Caller guidance

- Treat `NOTIFY_QUEUE_FULL` and `NOTIFY_RATE_LIMITED` as a reason to reduce or
  compact feedback, not to loop immediately.
- Use a stable dedupe/group key for a genuine repeatable burst.
- Do not escalate priority to obtain a queue slot.
- Do not rely on notification order for gameplay correctness.
- Keep durable state and retry authority in the owning domain.
