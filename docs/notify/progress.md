# Progress notifications

A background operation owns one notification identity from start to terminal
result. Update and morph that surface; do not emit a toast for every stage.

```text
PENDING -> RUNNING -> SUCCESS
                   -> FAILED
                   -> CANCELLED
PENDING ----------------^ (any terminal state)
```

Terminal states cannot transition again. Reusing a pre-update revision, moving a
terminal operation, or making running determinate progress go backwards returns
`NOTIFY_NOTIFICATION_STALE`.

## Modes

### Determinate

Use determinate mode only when the operation has a real measurable total.

```lua
progress = {
    state = 'RUNNING',
    mode = 'determinate',
    value = 12,
    maximum = 20,
}
```

`value` and `maximum` are finite numbers; `value` is at least zero and no more
than `maximum`; `maximum` is greater than zero and at most `1,000,000,000`.
While state remains `RUNNING`, a determinate-to-determinate update cannot reduce
`value`.

### Indeterminate

Use indeterminate mode when the backend cannot report real progress:

```lua
progress = {
    state = 'RUNNING',
    mode = 'indeterminate',
}
```

An indeterminate object must not contain `value` or `maximum`. Do not simulate a
0/20/40/60/80/100 sequence merely to animate the rail.

## Creating progress

`progress(...)` forces `kind = 'progress'`. If `payload.progress` is absent, it
defaults to running indeterminate progress.

A progress request must not contain `dedupeKey`, `dedupePolicy`,
`maxRefreshCount`, or `groupKey`. Validation rejects those combinations: one
operation owns one explicit mutable handle, so unrelated operations cannot be
silently compacted into the same progress lifecycle.

Client:

```lua
local notify, apiError = exports.synex_notify:GetAPI('^1.0.0')
if not notify then return nil, apiError end

local handle, progressError = notify.progress({
    title = 'Loading route',
    message = 'Resolving waypoints…',
    tone = 'info',
})
```

Server, using a previously resolved exact session reference:

```lua
local handle, progressError = notify.progress(target, {
    title = 'Purchasing vehicle',
    tone = 'info',
    progress = {
        state = 'RUNNING',
        mode = 'determinate',
        value = 1,
        maximum = 3,
    },
})
```

Creation returns the normal owner-bound handle. Default progress lifetime is the
120-second absolute maximum; it has no normal auto-dismiss duration while still
running.

## Updating and completing

Use the most recently returned handle:

```lua
handle, progressError = handle:update({
    message = 'Creating ownership record…',
    progress = {
        state = 'RUNNING',
        mode = 'determinate',
        value = 2,
        maximum = 3,
    },
})

if not handle then return nil, progressError end

handle, progressError = handle:success('Vehicle purchased')
```

Convenience terminal methods are:

| Method | State | Tone | Terminal duration |
| --- | --- | --- | --- |
| `handle:success(message?)` | `SUCCESS` | `success` | 4,000 ms |
| `handle:fail(message?)` | `FAILED` | `danger` | 4,000 ms |
| `handle:cancel(message?)` | `CANCELLED` | `neutral` | 4,000 ms |

They change only the terminal state/tone/message/duration and preserve the
current progress `mode`, `value`, and `maximum` exactly. This applies to both the
client convenience handle and the server completion/service path.
`handle:dismiss()` skips the terminal morph and removes the notification
explicitly; use it only when no result needs to be communicated.

The server service also exposes `cancel_progress` with
`{ handle, message? }`. It requires update authority and returns the next handle
descriptor.

## Coalescing and rendering

The client accepts every valid monotonic state update, but progress projection is
coalesced over a 100 ms window. The newest revision wins; stale browser or
transport revisions never move the rail backwards. This bounds NUI work without
changing the logical handle revision seen by the caller.

The Signal Surface renders a compact integrated rail. Determinate progress has
accessible minimum/maximum/current values; indeterminate progress omits a fake
current value. Completion/failure changes the same surface icon, tone, state
label, and rail before its terminal dismissal.

## Ownership, limits, and errors

- Progress consumes one normal notification/queue slot for its entire active
  lifetime.
- Every owner is limited by the same bounded-record and token budgets as other
  kinds.
- `maxLifetimeMs` remains a hard bound even if updates keep arriving.
- Owner stop cancels and removes the operation and invalidates actions.
- Server progress remains bound to the original session/source generation.
- A valid full server update may revive an inactive retained presentation before
  hard expiry; stale revisions and illegal/backward transitions are rejected
  before consuming the update budget.
- Use `NOTIFY_INVALID_REQUEST` for malformed progress, fields, or convenience
  calls on a non-progress record; `NOTIFY_NOTIFICATION_STALE` for an illegal
  transition/backward or outdated revision; and `NOTIFY_OWNER_STALE` /
  `NOTIFY_TARGET_STALE` for expired authority.

Automated tests cover state transitions, modes, bounds, backwards/revision
rejection, coalescing, and terminal rendering. Real long-running work, resource
stop/restart, UI restart, and CEF motion/performance still need live acceptance.
