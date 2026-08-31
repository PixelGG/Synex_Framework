# Grouping and burst compaction

Grouping combines related, non-identical events into one bounded presentation.
Deduplication answers "is this the same signal?"; grouping answers "can these
signals share one summary surface?"

## Request shape

```lua
local handle, notifyError = notify.show({
    kind = 'toast',
    tone = 'success',
    priority = 'normal',
    title = 'Water received',
    groupKey = 'inventory.received',
})
```

`groupKey` is a 1-96 byte identifier matching
`^[A-Za-z0-9][A-Za-z0-9_.:%-]*$`. There is no implicit grouping by resource,
title, or tone.

## Compatibility key

The 2,000 ms grouping window is scoped by the complete key:

```text
ownerResource + ownerEpoch + origin (LOCAL, SERVER, or SYSTEM)
+ groupKey + kind + tone + priority
```

This prevents a restarted owner, local/server/system origin, danger/neutral
tone, or normal/critical priority from collapsing into the same signal. A
privileged `SYSTEM` signal therefore cannot absorb an ordinary `SERVER` signal.
An expired
index is discarded. The window moves forward only when the compatible request
is successfully admitted and committed; capacity or rate rejection leaves the
previous timestamp unchanged.

Lookup/capacity and burst preflight happen before the atomic token debit and
group mutation. A grouped request is exempt from rejection solely by the raw
eight-request burst gate because it can compact, but every admitted member still
consumes the normal global, owner, kind, and applicable priority token budgets.
Privileged server kinds and priorities still require their capabilities and
dedicated budgets.

## Current compaction result

The first member becomes the representative. Each compatible member:

- increments `count`, capped at 9,999;
- replaces the representative title and message with the newest values;
- retains the exact kind, tone, and priority class;
- retains the representative's other fields and action set;
- keeps the representative's absolute lifetime ceiling.

The current public DTO does not accept an arbitrary item list or metadata blob.
If a player must inspect individual items, use an inventory/domain UI. Grouping
is a compact signal, not an activity log.

For server-originated groups, each admitted send retains its own server handle
and session fence. The client maps those source IDs to one visual
representative. Updating one member remains revision-fenced; dismissing one
member removes only that alias while the shared surface has other members.

## Dedupe interaction

When a request contains both keys, the dedupe lookup runs first. A dedupe hit
uses its declared policy; a dedupe miss **falls through to grouping**. A newly
created record is indexed for both applicable keys, so mixed strategies make
later ownership harder to reason about. In normal integrations, select exactly
one:

- dedupe identical facts with `dedupeKey`;
- compact related facts with `groupKey`.

The group compatibility key includes tone. If a representative's tone changes
through a valid update or dedupe replacement, Notify removes the old tone index
and reindexes the new key. Later requests cannot be absorbed through a stale
tone bucket.

## Safe use

Good group keys describe one reviewed UX class, such as repeated item receipts
or repeated low-value status changes. The caller still owns wording and domain
truth.

Do not group:

- unrelated errors merely because they share a resource;
- security or financial outcomes with different meaning;
- progress for independent operations;
- mixed urgency that should be scheduled separately;
- actions whose callback would be ambiguous after compaction.

Progress notifications reject grouping (and deduplication) at validation time;
each running operation must keep its own explicit handle.

If a precise multi-item summary is required, aggregate it in the owning domain
and send one bounded notification. Notify's built-in grouping only exposes the
latest title/message and a count.
