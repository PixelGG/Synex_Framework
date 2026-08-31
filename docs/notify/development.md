# Developing with Notify

> Status: **Experimental Alpha.** Repository tests are development evidence,
> not live FXServer/CEF approval.

The public API is experimental version `1.0.0`. Acquire it directly from the
resource that will own the notification:

```lua
local notify, apiError = exports.synex_notify:GetAPI('^1.0.0')
if not notify then
    return nil, apiError
end
```

Accepted version selectors are `^1.0.0`, `1`, `v1`, `1.0`, and `1.0.0`.
Unsupported ranges return `NOTIFY_PROTOCOL_UNSUPPORTED`. The facade captures the
immediate invoking resource and its current Notify-owned incarnation epoch; do
not wrap it in a shared broker that would become the apparent owner.

The server export normalizes failure to `false, error` so the second return
position survives raw Cfx transport. Client facade operations conventionally
return `nil, error`. In both environments, treat a non-nil second result as
authoritative:

```lua
local handle, notifyError = notify.show({ title = 'Route updated' })
if notifyError then
    print(notifyError.code)
    return
end
```

## Resource declaration

A server consumer declares the exact capabilities it needs and depends on Core
and Notify. Requesting a capability does not grant it; operator policy grants it
separately.

```json
{
  "capabilities": {
    "request": [
      "synex.notify.send",
      "synex.notify.update"
    ]
  },
  "dependencies": {
    "required": [
      { "name": "synex_core", "version": ">=0.1.0" },
      { "name": "synex_notify", "version": ">=0.1.0" }
    ],
    "optional": [],
    "development": []
  }
}
```

Add `dependency 'synex_notify'` to the consumer `fxmanifest.lua` (and
`synex_core` when the server code resolves sessions or calls the service). Keep
the resource inside the repository's `synex_` namespace.

## Canonical notification payload

Only `title` is required. The object is closed; unknown fields are rejected.

| Field | Input and default | Limit/meaning |
| --- | --- | --- |
| `kind` | enum, default `toast` | `toast`, `progress`, `persistent`, `banner`, `status` |
| `tone` | enum, default `neutral` | `neutral`, `info`, `success`, `warning`, `danger` |
| `priority` | enum, default `normal` | `low`, `normal`, `high`, `critical` |
| `title` | required string | 1–120 bytes; control characters rejected |
| `message` | optional string | 0–720 orchestration bytes; control characters rejected; client UI projection uses a Unicode-safe 512-byte prefix |
| `iconKey` | optional registry key | no arbitrary image/SVG/URL |
| `dedupeKey` | optional identifier | 1–96 bytes |
| `dedupePolicy` | optional enum | requires a key; default `suppress`; also `count`, `replace`, `refresh` |
| `maxRefreshCount` | optional integer | valid only with `dedupePolicy = 'refresh'`; default 4, maximum 32 |
| `groupKey` | optional identifier | 1–96 bytes |
| `durationMs` | optional integer | 1,500–30,000; calculated from content/kind/priority when omitted for toast/status/banner |
| `maxLifetimeMs` | optional integer | 3,000–120,000; default 120,000; cannot be shorter than an explicit duration and always caps a calculated duration |
| `history` | optional boolean | default `true`; history remains bounded/in-memory |
| `position` | optional enum | default `top-right`; six corner/center-edge positions |
| `progress` | optional closed object | valid only for `progress`; absent progress defaults to running/indeterminate; progress rejects dedupe/group fields |
| `actions` | optional dense array | at most 2 definitions |
| `sound` | optional boolean | default `false`; still subject to preference/cooldown/policy |

Identifier fields use `^[A-Za-z0-9][A-Za-z0-9_.:%-]*$`. The canonical encoded
payload is capped at 4,096 bytes. Strings are byte-bounded in Lua, so localized
multi-byte text can reach the byte limit before its character count suggests.

`origin` is not an input field. Notify derives `LOCAL` for client facades and
`SERVER` for normal server sends. The reserved `SYSTEM` value is available only
through the dedicated privileged methods described below; adding
`origin = 'SYSTEM'` to an ordinary payload is rejected as an unknown field.

The calculated duration is the clamped result of `2,800 ms + 32 ms` per Unicode
character in `title .. message`, plus priority bonus (`0/500/1,500/2,500` for
low/normal/high/critical) and kind bonus (`0/1,000/2,500` for
toast/status/banner). Explicit duration remains bounded, and the absolute
maximum lifetime always wins.

Controlled icon keys are:

```text
check close chevron-down chevron-right arrow-left arrow-right search
plus minus more copy eye eye-off info warning error success menu command signal
```

### Progress object

```lua
{
    state = 'RUNNING', -- PENDING | RUNNING | SUCCESS | FAILED | CANCELLED
    mode = 'determinate', -- determinate | indeterminate
    value = 20,
    maximum = 100,
}
```

Determinate values are finite, `0 <= value <= maximum`, and maximum is at most
`1,000,000,000`. Indeterminate progress omits both numeric fields.

### Action definition

```lua
{
    id = 'retry',
    label = 'Retry',
    hint = 'G',
    style = 'primary', -- primary | quiet | danger
    ttlMs = 10000,
}
```

`id` is 1–64 identifier bytes, `label` is 1–64 text bytes, and `hint` is 1–24
text bytes. TTL is 1,000–30,000 ms and defaults to 10,000 ms. Callers never
supply the transport token. The configured TTL is clipped to the current
presentation deadline and hard lifetime; the exact deadline is expired and a
queued action can expire before promotion.

## Client facade

The client facade reports `version`, `ownerResource`, `ownerEpoch`, and the
shared read-only `limits`. It exposes:

| API | Input | Result | Ownership, lifecycle, and limits | Main errors |
| --- | --- | --- | --- | --- |
| `show(request)` | canonical payload | callable local handle | caller/epoch-owned; defaults to toast/neutral/normal/top-right; client denies banner/high/critical | invalid, priority denied, rate limited, queue full, unavailable |
| `progress(request)` | canonical payload | callable local progress handle | forces progress and defaults to running/indeterminate | same plus invalid progress |
| `setPresentationContext(request)` | bounded context object | normalized context | owner/epoch-bound; at most 16 active contexts client-wide | invalid, owner stale, context limit |
| `clearPresentationContext(contextId)` | safe context ID | `{ cleared = boolean }` | only the calling owner epoch can clear its context | invalid, owner stale |
| `getPresentationSnapshot()` | no input | effective context/preferences snapshot | read-only, current client process | owner stale |
| `getHistory(limit?)` | optional integer, default 32 | owner-filtered metadata entries, newest first | 1–128; no title/message; in memory only | invalid, owner stale |
| `getDiagnostics()` | no input | bounded client snapshot | counts, client metrics/queue wait, UI bind state, and effective presentation policy/preferences | owner stale |

A presentation context has this closed shape:

```lua
local context, contextError = notify.setPresentationContext({
    contextId = 'phone.open',
    quiet = true,
    reservedPositions = { 'bottom-right' },
    preferredPosition = 'top-right',
    fallbackPositions = { 'top-left', 'top-center' },
})

-- Clear it when the owning surface closes; owner stop also clears it.
local cleared, clearError = notify.clearPresentationContext('phone.open')
```

`contextId` is a 1–64 byte safe identifier. Position arrays are dense, unique,
contain only canonical positions, and contain at most six entries. Quiet is
combined across contexts; low/normal signals wait, while high/critical remain
eligible under all normal budgets. When a signal's requested position is
reserved, placement tries an unreserved preferred position, declared fallbacks,
then a deterministic canonical order. There are no arbitrary pixel offsets. A
fully reserved screen retains the signal's requested canonical position rather
than inventing geometry. A context change revision-reprojects visible signals.

Client diagnostics include effective `quiet`, `contextCount`, reserved,
preferred, and fallback positions, plus read-only `synex_ui` preferences for
scale, reduced motion, reduced transparency, and high contrast. The snapshot's
`preferences` object also includes the process-local Notify preferences below.

### Local presentation preferences

These controls belong to the local player. They are not part of a resource
facade, so a gameplay resource cannot silently change another user's
presentation policy.

| Local command | Accepted value | Default | Effect |
| --- | --- | --- | --- |
| `synex-notify-position` | `auto` or one of the six canonical positions | `auto` | prefers one unreserved rail position |
| `synex-notify-duration-scale` | integer `50..200` | `100` | scales timed presentation duration as a percentage |
| `synex-notify-sound` | `on`, `off`, or `toggle` | `off` | enables or disables eligible notification sounds |
| `synex-notify-sound volume` | integer `0..100` | `100` | controls the shared UI one-shot gain; zero suppresses sound before transport |
| `synex-notify-sound critical-only` | `on`, `off`, or `toggle` | `off` | mutes non-critical notification sounds only |
| `synex-notify-history` | `on`, `off`, or `toggle` | `on` | permits or suppresses future lifecycle-history entries |

Commands are client-local and last only for the current `synex_notify` client
resource process. They are not written to KVP, a database, or a profile and
reset when that process restarts. Current values are available through
`getPresentationSnapshot()` and `getDiagnostics()`.

Position changes re-plan current and future signals, but an active presentation
context can reserve that position and force the normal deterministic fallback.
Duration scale is applied when timed content is admitted or receives a duration
update; it does not rewrite already running deadlines. The canonical
1,500-30,000 ms duration bounds and immutable maximum lifetime still win after
scaling. `critical-only` affects audio, not notification priority, visibility,
or live-region behavior. Disabling history leaves existing bounded entries in
memory and suppresses only later additions.

Eligible audio uses `synex_ui`'s private, non-retained Signal Sound path. It
accepts only the closed semantic tones `neutral`, `info`, `success`, `warning`,
`danger`, and `critical` plus an integer gain preference from 1 through 100.
It creates no surface, focus, pointer layer, network request, or replayable
runtime state. The internal envelope adds a Lua-owned browser-boot fence; CEF
also rejects duplicate message IDs and stale owner epochs, repeats the bounded
rate limits, and caps concurrent voices. A missing/blocked browser audio
context fails silently because sound is supplementary; real CEF/device
loudness remains a live acceptance item.

When an action omits its optional `hint`, `synex_ui` renders the mapping for its
central current input device: F9/F10 for keyboard or mouse state and D-pad
Left/Right for gamepad state. Notify does not run a separate device detector;
the UI runtime samples only the input source while passive signals exist and
captures no controls. An explicit hint remains presentation text and does not
register or authorize a new binding.

### Read lifecycle history

History belongs to the resource that acquired the client facade. It contains
bounded lifecycle metadata only; notification text is deliberately absent.

```lua
local entries, historyError = notify.getHistory(20)
if not entries then
    print(('Notify history failed: %s'):format(historyError.code))
    return
end

for _, entry in ipairs(entries) do
    print(('%s %s (%s) at %d'):format(
        entry.notificationId,
        entry.state,
        entry.reason,
        entry.occurredAt
    ))
end
```

Results are newest first. The limit is optional, defaults to 32, and must be an
integer from 1 through 128. Do not use this process-local history as durable
gameplay state or as an audit log. Each metadata entry includes the derived
`origin` (`LOCAL`, `SERVER`, or `SYSTEM`) without exposing notification text.

## Handle shape and methods

Creation returns a handle with data plus caller-bound methods:

```text
notificationId  ownerResource  ownerEpoch  revision
update           success        fail        cancel
dismiss          onAction
```

Every mutation consumes the current revision. The convenience handle updates
its own descriptor after success and returns itself; keep the returned value so
code also works with plain descriptors returned by services/contracts. Stale
revision returns `NOTIFY_NOTIFICATION_STALE`; stopped/restarted owner returns
`NOTIFY_OWNER_STOPPED` or `NOTIFY_OWNER_STALE`.

The handle's `ownerEpoch` is the canonical `synex_notify` incarnation for that
resource, not a copied Core-service caller epoch. Direct-facade, Core-service,
and Bridge entry paths resolve to the same Notify-owned epoch.

| Method | Input | Result | Lifecycle and limits | Main errors |
| --- | --- | --- | --- | --- |
| `handle:update(patch)` | non-empty allowed patch | next handle | monotonic update; server fields are title/message/tone/duration/progress/actions | invalid, owner/target/not-found/stale, unavailable |
| `handle:success(message?)` | optional text | next handle | progress only; terminal `SUCCESS`, success tone, 4 s terminal duration; preserves mode/value/maximum | invalid, not-found/stale, owner/target stale |
| `handle:fail(message?)` | optional text | next handle | progress only; terminal `FAILED`, danger tone, 4 s; preserves mode/value/maximum | same |
| `handle:cancel(message?)` | optional text | next handle | progress only; terminal `CANCELLED`, neutral tone, 4 s; preserves mode/value/maximum | same |
| `handle:dismiss(reason?)` | `dismissed`, `cancelled`, or `superseded` | `{ notificationId, dismissed = true }` | terminal removal and action invalidation | invalid, not-found/stale, owner/target stale |
| `handle:onAction(actionId, callback)` (client) / `handle:onAction(actionId?, callback)` (server) | action filter/callable | `true` | local callbacks require one declared ID; the bounded server map accepts either a declared ID or one wildcard and prunes replaced IDs | invalid, not-found/action, owner stale |

The client patch surface additionally permits `iconKey`, `count`, `position`,
and `sound`. Kind, priority, dedupe/group identity, creation time, and maximum
lifetime are immutable.

## Server target reference

Resolve and copy the exact active session immediately before sending:

```lua
local core, coreError = exports.synex_core:GetAPI('^1.0.0')
if not core then return nil, coreError end

local session, sessionError = core.Players.getBySource(playerSource)
if not session then return nil, sessionError end

local target = {
    source = session.source,
    sessionId = session.id,
    sourceGeneration = session.sourceGeneration,
}
```

`source` is integer `1..65535`; session ID is an 8–64 byte bounded identifier;
source generation is a positive safe integer. Notify revalidates all three.

## Direct server facade

The direct server facade reports `version`, `ownerResource`, `ownerEpoch`, and
the compact `limits` projection (`sendMany = 32`, `actions = 2`, `queue = 128`,
`visible = 4`). `visible` is the hard maximum; the client derives an active
capacity from one through four for its current safe viewport, scale, and
density. The facade exposes:

| API | Input | Result | Ownership/lifecycle | Limits and capability | Main errors |
| --- | --- | --- | --- | --- | --- |
| `send(target, payload)` | exact target + canonical payload | callable handle | creates one server record for canonical Notify owner epoch and target session | 512 global records, 256/owner; weighted global/owner/kind/priority budgets; `send`; extra high/critical/banner gates | invalid/owner/target, priority denied, rate limited, queue full, unavailable |
| `show`, `notify` | same as `send` | same | exact aliases | same | same |
| `sendSystem(target, payload)` | exact target + canonical payload | callable handle | creates a reserved `SYSTEM` record; `showSystem` and `notifySystem` are exact aliases | built-in Core principal or `synex.notify.system`, plus normal send/priority/banner gates | invalid/owner/target/capability, priority denied, rate limited, queue full, unavailable |
| `progress(target, payload)` | target + payload | progress handle | forces kind `progress`, defaults running/indeterminate | same admission limits | same plus invalid progress |
| `update(handle, patch)` | plain/callable handle + non-empty server patch | fresh callable handle | exact caller owner/epoch/revision | update capability and update bucket | invalid, not found/stale, owner/target stale, rate limited/unavailable |
| `dismiss(handle, reason?)` | handle + optional normal reason | terminal result | removes record/actions/history entry | update capability/bucket | invalid, not found/stale, owner/target stale |
| `sendMany(targets, payload)` | dense target array + one payload | partial aggregate | each successful target gets an independent handle | 1–32 targets; normal send gates/costs apply per target | invalid plus per-item error codes |
| `broadcast(payload)` | one payload | partial aggregate | derives current active session refs; no client-selected list | at most 256 targets; broadcast plus normal/priority/banner gates | owner/priority, queue full, rate limited, unavailable |
| `sendManySystem(targets, payload)` | same as `sendMany` | partial aggregate | every successful record has reserved `SYSTEM` origin | system plus normal per-target gates | same as `sendMany` |
| `broadcastSystem(payload)` | same as `broadcast` | partial aggregate | bounded active-session `SYSTEM` delivery | system, broadcast, and normal priority/banner gates | same as `broadcast` |
| `getDiagnostics()` | no input | bounded snapshot | current process only | `synex.notify.diagnostics.read` | owner/capability/unavailable |

`sendMany` and `broadcast` return:

```lua
{
    sent = 2,
    failed = 1,
    handles = { -- successful handles only },
    errors = {
        { index = 3, code = 'NOTIFY_TARGET_STALE' },
    },
}
```

Partial failure is a successful aggregate result; inspect `failed` and
`errors`. Broadcast does not retry or persist offline targets.

### Send one notification to several exact sessions

Build every target from a freshly resolved Core session. Do not reuse a player
source by itself and do not accept a client-supplied session fence.

```lua
local targets = {}
for _, source in ipairs({ firstPlayerSource, secondPlayerSource }) do
    local session, sessionError = core.Players.getBySource(source)
    if not session then
        print(('Session resolution failed: %s'):format(sessionError.code))
        return
    end
    targets[#targets + 1] = {
        source = session.source,
        sessionId = session.id,
        sourceGeneration = session.sourceGeneration,
    }
end

local batch, batchError = notify.sendMany(targets, {
    kind = 'toast',
    tone = 'info',
    priority = 'normal',
    title = 'Briefing updated',
})
if not batch then
    print(('Notify batch failed: %s'):format(batchError.code))
    return
end

if batch.failed > 0 then
    for _, item in ipairs(batch.errors) do
        print(('Target %d failed: %s'):format(item.index, item.code))
    end
end
```

`sendMany` accepts 1 through 32 dense target references. The result contains
callable handles only for successful deliveries; an item-level failure does not
roll back other sends.

### Broadcast to the current active sessions

Broadcast is server-only and requires both `synex.notify.send` and
`synex.notify.broadcast`. Notify derives the bounded active-session target set;
the caller supplies no player list.

```lua
local broadcast, broadcastError = notify.broadcast({
    kind = 'toast',
    tone = 'info',
    priority = 'normal',
    title = 'Server notice',
    message = 'A scheduled restart begins in 30 minutes.',
})
if not broadcast then
    print(('Notify broadcast failed: %s'):format(broadcastError.code))
    return
end

print(('Notify broadcast: %d sent, %d failed'):format(
    broadcast.sent,
    broadcast.failed
))
for _, item in ipairs(broadcast.errors) do
    print(('Active target %d failed: %s'):format(item.index, item.code))
end
```

The active set is capped at 256 targets. Normal send validation, capability,
budget, target-fencing, and partial-failure rules still apply per session.

Server timed presentations become inactive after their conservative send-time
window, but their revisioned records remain retained until hard expiry or
oldest-inactive pressure eviction. A newer full update can revive a retained
record. The client owns actual queue/visible timing and may hold bounded dormant
state or a tombstone for that handle; neither side treats retention as proof of
browser paint.

## `synex.notify@1` server service

Server resources that prefer Core service discovery call:

```lua
local result, serviceError = core.Services.call(
    'synex.notify',
    '^1.0.0',
    'send',
    { target = target, payload = { title = 'Route updated' } },
    { timeoutMs = 3000 }
)
```

The second result is authoritative. Service results contain plain handle
descriptors, not callable convenience methods.

Core supplies and Notify validates the immediate service caller's
`callerEpoch`, but Notify then resolves the caller resource to its own canonical
resource-incarnation epoch. The service cannot choose either owner identity or
the record epoch.

| Method | Capability | Exact request | Result |
| --- | --- | --- | --- |
| `send` | `synex.notify.send` | `{ target, payload }` | handle descriptor |
| `send_many` | `synex.notify.send` | `{ targets, payload }` | partial aggregate |
| `broadcast` | `synex.notify.broadcast` | `{ payload }` | partial aggregate |
| `send_system` | `synex.notify.system` | `{ target, payload }` | `SYSTEM` handle descriptor; normal send/priority/banner gates are rechecked |
| `send_many_system` | `synex.notify.system` | `{ targets, payload }` | partial `SYSTEM` aggregate; normal gates are rechecked per target |
| `broadcast_system` | `synex.notify.system` | `{ payload }` | partial `SYSTEM` aggregate; broadcast and normal gates are rechecked |
| `update` | `synex.notify.update` | `{ handle, patch }` | next handle descriptor |
| `dismiss` | `synex.notify.update` | `{ handle, reason? }` | terminal result |
| `cancel_progress` | `synex.notify.update` | `{ handle, message? }` | next cancelled handle descriptor |
| `get_control_summary` | `synex.notify.diagnostics.read` | `{}` | bounded aggregate status |
| `doctor` | `synex.notify.diagnostics.read` | `{ limit? }` | bounded findings report; limit 1–100 |

Every method inherits the same owner epoch, target, lifecycle, payload, record,
rate, and error boundary as the direct facade. High/critical/banner still require
their extra capabilities inside a normal or system send. Only `synex_core` is a
built-in system principal; another framework resource must declare and receive
`synex.notify.system` explicitly.

## Canonical Core contracts

Six experimental definitions are checked in:

| Contract | Network | Capability/session | Purpose |
| --- | --- | --- | --- |
| `synex.notify.send@1.0.0` | `none` | `synex.notify.send` | target-fenced send |
| `synex.notify.update@1.0.0` | `none` | `synex.notify.update` | revisioned update |
| `synex.notify.dismiss@1.0.0` | `none` | `synex.notify.update` | revisioned dismissal |
| `synex.notify.command.pull@1.0.0` | client-to-server | active Core session | internal single-consumer retrieval of a target-fenced pending command |
| `synex.notify.action.invoke@1.0.0` | client-to-server | active Core session | token/revision action invocation |
| `synex.notify.metrics.report@1.0.0` | client-to-server | active Core session | internal, aggregate-only presentation telemetry |

Use the facade/service for normal integration. Never create a separate network
event that forwards arbitrary notification operations. `command.pull` is an
internal transport contract, not an application integration API: the raw Cfx
wake event carries only its opaque ID and never a notification payload.
`metrics.report` is likewise runtime-internal. Its closed payload contains fixed
absolute counters, bounded queue gauges, a client generation, and a sequence;
it contains no notification content, resource/player/session ID, action token,
or trace ID. The server establishes a baseline before deriving bounded deltas,
so gameplay resources must not call it and operators must not use its
client-reported values as delivery or authorization evidence.

## Error model

Notify failures have the public shape:

```lua
{
    code = 'NOTIFY_RATE_LIMITED',
    message = 'The notification budget is temporarily exhausted.',
    retryable = true,
}
```

Branch on `code`, never on `message`, and treat the supplied `retryable` flag as
authoritative. Retryable means the infrastructure condition may clear; it does
not mean immediately retrying player-facing feedback is good UX. Server facade
failures use `false, error`; client facade/handle and service operations use the
normal nil/error form inside their boundary. Core may add its own trace envelope
around service/RPC failures.

| Code | Meaning |
| --- | --- |
| `NOTIFY_INVALID_REQUEST` | closed shape, type, text, enum, range, transition, or reason is invalid |
| `NOTIFY_PROTOCOL_UNSUPPORTED` | requested API version selector is unsupported |
| `NOTIFY_OWNER_INVALID` | caller identity/context is invalid or lacks a non-priority operation capability |
| `NOTIFY_OWNER_STOPPED` | the captured owner resource is no longer active |
| `NOTIFY_OWNER_STALE` | facade/handle belongs to another owner incarnation |
| `NOTIFY_RATE_LIMITED` | an atomic token/burst/action or bounded token-registry budget rejected work |
| `NOTIFY_QUEUE_FULL` | bounded client/server record or broadcast-target capacity cannot admit the request |
| `NOTIFY_CONTEXT_LIMIT` | the bounded 16-entry client presentation-context registry is full |
| `NOTIFY_INVALID_PRIORITY` | contract vocabulary for an invalid priority request; current closed validation generally reports malformed enums as `NOTIFY_INVALID_REQUEST` |
| `NOTIFY_PRIORITY_DENIED` | client or server caller cannot use the requested privileged presentation |
| `NOTIFY_COMMAND_NOT_FOUND` | internal pending command is unknown, consumed, or expired; it creates no client state |
| `NOTIFY_NOTIFICATION_NOT_FOUND` | record or action owner no longer exists |
| `NOTIFY_NOTIFICATION_STALE` | handle/revision/transition is out of date or illegal |
| `NOTIFY_ACTION_NOT_FOUND` | action/token is absent, hidden, or has no handler |
| `NOTIFY_ACTION_EXPIRED` | action TTL elapsed |
| `NOTIFY_ACTION_REPLAYED` | a retained single-use token was already consumed |
| `NOTIFY_TARGET_STALE` | source, session ID, or source generation no longer matches |
| `NOTIFY_UI_UNAVAILABLE` | optional Signal Surface transport is unavailable; normal sends may still be admitted in degraded mode |
| `NOTIFY_PAYLOAD_TOO_LARGE` | contract vocabulary for the 4 KiB payload boundary; field-level bounds normally reject first |
| `NOTIFY_UNAVAILABLE` | transient service, transport, Core, callback, ID, or Control dependency failure |
| `NOTIFY_INTERNAL_ERROR` | an unexpected exception was normalized without leaking internals |

## Testing and review

Run only repository-defined commands from the repository root:

```text
npm run check
npm run test:notify
npm test
npm run security
node --experimental-strip-types tools/cli/src/bin.ts certify resource resources/synex_notify
```

The root commands discover the checked-in focused Lua and UI suites.
`npm run test:ui:visual` is the browser screenshot gate; it does not launch
FiveM.

Automated success proves deterministic source/schema/browser behavior only. The
Experimental Alpha implementation still needs live FXServer and real-client testing
for Core/UI start order, player reconnect/source reuse, owner restart, Notify/UI
restart, focus coexistence, action keyboard/gamepad paths, CEF accessibility,
native fallback, safe zones, ultrawide/4K layout, controller behavior, and
measured Resmon/load behavior.
