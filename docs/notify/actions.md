# Notification actions

Actions provide one or two short, optional shortcuts such as Retry, Undo, or
Open. The Signal Surface remains display-only and pointer-free: it shows input
hints but never takes NUI focus. Multi-step choices, data entry, and confirmation
flows belong in a `synex_ui` dialog.

## Definition and limits

```lua
actions = {
    {
        id = 'retry',
        label = 'Retry',
        style = 'primary',
        ttlMs = 10000,
    },
}
```

| Field | Rule |
| --- | --- |
| `id` | 1-64 byte bounded identifier, unique within the notification |
| `label` | 1-64 byte plain text |
| `hint` | optional 1-24 byte display text; it does not register a new key mapping |
| `style` | `primary`, `quiet`, or `danger` |
| `ttlMs` | 1,000-30,000 ms; default 10,000 ms |

There are at most two actions per notification and at most 512 outstanding
server action tokens. Callers cannot provide a token, callback name, event name,
URL, or arbitrary payload.

The effective action deadline is the earliest of its requested `ttlMs`, the
notification's current presentation deadline, and `createdAt + maxLifetimeMs`.
The exact deadline is expired, not usable. The server uses a conservative
send-time presentation deadline because it cannot observe client queue
promotion; the client clips again to the actual visible expiry when a record is
promoted. An action can therefore expire while its notification is still queued
and is never allowed to outlive the surface on which it was usable. Ordinary
updates can shorten an existing token but cannot extend it. A dormant server
presentation has no actions; a revived presentation needs newly issued action
definitions if it should expose shortcuts again.

When `hint` is omitted, the client displays its active mapping: Action 1 is F9
or gamepad D-pad Left, and Action 2 is F10 or gamepad D-pad Right. A configured
hint is presentation text only; the owner must not imply an unavailable binding.
The global commands select only a currently visible, unexpired action. Among
eligible surfaces, the highest priority wins and the oldest visible surface
breaks a priority tie.

"Visible" is browser-confirmed, not merely selected by Notify's planned stack.
New action descriptors are initially withheld. The Signal Surface reports only
DOM entries in its actual `active` phase (never a retained 140 ms dismissing
entry), together with the current signal generation, exact signal revisions,
adaptive capacity, and a strictly increasing per-browser-boot
`presentationRevision`. That first
report permits Notify to project the hint; the resulting action-bearing revision
must then itself be confirmed before F9/F10 can invoke it. This prevents an
exiting or globally displaced surface from keeping a command shortcut.

The browser retries a failed visibility callback after 150, 500, 1,500, and
5,000 ms, then every five seconds. Notify also polls the owner-only UI snapshot
while action tokens remain. A CEF reload, UI restart, missing/stale ACK, failed
retry, generation mismatch, or revision mismatch therefore fails closed: no
hint is newly exposed and F9/F10 does not invoke an action until a current ACK
succeeds.

## Local client action

Client resources register a callback for an action ID on their handle:

```lua
local notify, apiError = exports.synex_notify:GetAPI('^1.0.0')
if not notify then return nil, apiError end

local handle, notifyError = notify.show({
    title = 'Route unavailable',
    tone = 'warning',
    actions = {
        { id = 'retry', label = 'Retry', style = 'primary' },
    },
})
if not handle then return nil, notifyError end

local registered, actionError = handle:onAction('retry', function(action)
    -- Revalidate local state before retrying the operation.
    requestRouteAgain(action.notificationId)
end)
```

Local callbacks receive `{ notificationId, actionId, revision }`. Register each
declared local action explicitly. The callback is owner/epoch-bound and is
removed when the record expires, is dismissed, is evicted, or its owner stops.

## Server action

The server issues opaque tokens and validates the active target session on
invocation. A wildcard notification-level callback can branch on the bounded
`actionId` when there are two actions:

```lua
local core = assert(exports.synex_core:GetAPI('^1.0.0'))
local notify = assert(exports.synex_notify:GetAPI('^1.0.0'))
local session = assert(core.Players.getBySource(playerSource))

local target = {
    source = session.source,
    sessionId = session.id,
    sourceGeneration = session.sourceGeneration,
}

local handle, notifyError = notify.send(target, {
    title = 'Connection interrupted',
    tone = 'warning',
    actions = {
        { id = 'retry', label = 'Retry', style = 'primary' },
        { id = 'dismiss', label = 'Dismiss', style = 'quiet' },
    },
})
if not handle then return nil, notifyError end

local registered, actionError = handle:onAction(function(action)
    -- Authorize again against current server state. The token is not gameplay authority.
    if action.actionId == 'retry' then
        retryConnection(action.session)
    end
end)
```

The server callback receives
`{ notificationId, actionId, ownerResource, session, occurredAt, traceId }`.
`handle:onAction('retry', callback)` registers an ID-specific handler;
`handle:onAction(callback)` registers a wildcard fallback. The registry keeps a
bounded map per notification (at most the two declared action IDs plus the
wildcard), prefers an exact ID handler, and removes ID-specific handlers when a
later action replacement no longer declares that ID.

## Token and replay boundary

A server token is bound to the notification ID and revision, owner resource and
epoch, action ID, expiry, and exact `{source, sessionId, sourceGeneration}`
target. The client-to-server contract accepts only the token, notification ID,
and revision and requires an active Core session.

Invocation checks visibility on the client and action rate limits, then marks
the action used before calling local code or server transport. The server again
checks token existence, expiry, replay state, revision, and session fence before
calling the owner. A repeated call is rejected as `NOTIFY_ACTION_REPLAYED`
while the used token remains, or `NOTIFY_ACTION_NOT_FOUND` after cleanup.

Relevant failures are `NOTIFY_ACTION_NOT_FOUND`, `NOTIFY_ACTION_EXPIRED`,
`NOTIFY_ACTION_REPLAYED`, `NOTIFY_NOTIFICATION_STALE`,
`NOTIFY_TARGET_STALE`, `NOTIFY_OWNER_STALE`, `NOTIFY_RATE_LIMITED`, and
`NOTIFY_UNAVAILABLE`.

`synex_ui` does not expose this visibility authority as a general passive-signal
bus. Its raw `upsertSignal`, `removeSignal`, `getSignalSnapshot`, and adaptive
capacity binding accept only the immediate `synex_notify` resource; other owners
fail with `UI_SIGNAL_DENIED` for transport and never receive the binding method.

## Security rule

An accepted action proves only that one current notification shortcut was used.
It does not prove proximity, balance, inventory ownership, permissions, or
entity authority. Re-resolve and authorize all mutable gameplay state in the
owning server domain before making a change.
