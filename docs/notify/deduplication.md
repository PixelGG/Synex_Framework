# Deduplication

Deduplication compacts repeated reports of the same fact into one client
surface. It is an explicit presentation rule, not delivery idempotency and not
a substitute for idempotency in the owning gameplay domain.

## Request shape

Set a stable, bounded key and optionally choose a policy:

```lua
local handle, notifyError = notify.show({
    title = 'Vehicle is locked',
    tone = 'warning',
    dedupeKey = 'vehicle.locked',
    dedupePolicy = 'count',
})
```

`dedupeKey` is a 1-96 byte identifier matching
`^[A-Za-z0-9][A-Za-z0-9_.:%-]*$`. `dedupePolicy` requires a key and defaults to
`suppress`. The other values are `count`, `replace`, and `refresh`. A refresh
policy accepts `maxRefreshCount = 1..32` (default 4). Notify does not derive an
automatic key when one is absent.

## Match boundary

A match requires the same:

```text
ownerResource + ownerEpoch + origin (LOCAL, SERVER, or SYSTEM) + dedupeKey
```

The window is 2,000 ms. An expired index is discarded and the request can create
a new representative. The timestamp moves forward only after the matching
request passes capacity, burst, and atomic token admission and is committed;
`NOTIFY_QUEUE_FULL`, `NOTIFY_RATE_LIMITED`, or another failed admission does not
extend the window. Owner restarts cannot collide with an earlier epoch, and a
local notification cannot absorb or return a handle for a server-authoritative
one. A privileged `SYSTEM` notification is also isolated from an ordinary
`SERVER` notification with the same owner and key. `SYSTEM` is reserved and
cannot be selected by ordinary payload input.

Notify performs lookup/capacity and burst preflight before the atomic token
debit, then commits the selected policy. A keyed request has a bounded
compaction path and therefore is not rejected only by the raw eight-request
burst gate, but every successfully admitted match still consumes global, owner,
kind, and applicable priority tokens.

## Policies

| Policy | Existing client surface | Result |
| --- | --- | --- |
| `suppress` | unchanged | returns the existing local handle, or aliases the server source handle to the representative |
| `count` | increments the bounded count, up to 9,999 | retains representative content and actions |
| `replace` | replaces the complete presentation and resets its aggregate count to the replacement count/default | keeps the surface identity, visible-time anchor, and original hard-lifetime anchor |
| `refresh` | renews the current visible duration | stops after `maxRefreshCount` and never moves the absolute `createdAt + maxLifetimeMs` ceiling |

`suppress`, `count`, and `refresh` do not merge action definitions from the new
request. `replace` installs the replacement presentation, including its action
set. Avoid attaching actions to a repeated burst unless those semantics are
unambiguous.

If both `dedupeKey` and `groupKey` are supplied, deduplication is evaluated
first. A dedupe **miss** continues to the compatible group lookup rather than
preventing grouping. Prefer one mechanism per call so ownership and update
behavior are clear.

## Handles and server aliases

For a local request, a dedupe hit returns the representative notification
handle. Keep the returned handle because its revision can differ from an older
copy.

Each server `send` still creates a bounded, owner/session-fenced server record
and returns its own server handle. The target client may compact several such
records into one visual representative. It tracks source aliases so a later
server update or dismissal is revision-checked against the correct source.
Dismissal of one source member does not remove the shared surface while other
server members remain.

Consequently, a successful server send means the command was admitted and
dispatched; it is not a receipt proving that the browser painted a distinct
card.

## Lifetime and correctness

The maximum lifetime is bounded to 3,000-120,000 ms and is anchored to the
representative's original creation time. The refresh count is immutable for the
representative once selected; capped refreshes return the same handle without a
new revision or duration extension. Refresh spam therefore cannot keep a signal
alive forever. Queued representatives can expire without becoming visible.

Normal handle updates and `replace` do not refresh the visible duration. The
dedupe `refresh` policy is the only dedupe operation that renews reading time;
it never changes the hard deadline. Progress payloads reject both `dedupeKey`
and `groupKey` because one operation must retain one explicit handle.

Use a dedupe key only when repeated events communicate the same user-facing
fact. Never deduplicate transaction execution, inventory mutation, permission
checks, or other domain work through Notify. Commit that work idempotently in
its owning service, then deduplicate only the feedback.

## Choosing a policy

- Use `suppress` when one notice is sufficient and repeat count is irrelevant.
- Use `count` when frequency helps the player but the message is otherwise the
  same.
- Use `replace` when the newest description supersedes the previous one.
- Use `refresh` when the same transient condition is still current and its
  visible reading time should restart within the hard lifetime.
- Use [grouping](grouping.md) when related events are not duplicates.
