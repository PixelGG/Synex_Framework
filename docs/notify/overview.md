# Synex Feedback & Notification Orchestration

`synex_notify` is the framework's bounded, owner-aware, session-safe feedback
engine. It coordinates notification lifecycle, queue pressure, priority,
deduplication, grouping, progress, actions, presentation policy, and diagnostics;
`synex_ui` renders its passive Signal Surface.

The guiding rule is:

> **Notify only when the information would otherwise be missed.**

## Choose the right feedback surface

| Situation | Use |
| --- | --- |
| The result is already visually obvious | No extra message |
| A form, inventory, banking app, or other relevant UI is open | Inline state/error |
| The player must choose, confirm, enter data, or review details | `synex_ui` dialog |
| A bounded background operation changes over time | One Notify progress surface |
| A short result would otherwise be missed | Notify toast |
| A bounded ongoing degraded condition matters | Notify status/persistent signal |
| Information must survive restart or be reviewed later | Owning domain state/inbox, not Notify |

Do not emit “Door opened”, “Item moved”, “Menu opened”, or similar success
toasts when the state change is already visible. A phone push inbox belongs to
`synex_phone`; a transfer record belongs to accounts/banking; audit facts belong
to the audit system.

## Client quick start

Client resources obtain a caller-bound facade. Notify derives the resource name
and local owner epoch; the payload cannot choose either.

```lua
local notify, apiError = exports.synex_notify:GetAPI('^1.0.0')
if not notify then
    print(apiError.code)
    return
end

local handle, notifyError = notify.show({
    kind = 'toast',
    tone = 'success',
    priority = 'normal',
    title = 'Vehicle stored',
    message = 'The garage now owns the current parking state.',
})

if notifyError then print(notifyError.code) end
```

Client calls create local feedback only. They cannot target another player,
request `banner`, use high/critical priority, or claim system origin.

## Server quick start

Never target a player by bare Cfx source. Resolve the current Core session and
pass the exact `source + sessionId + sourceGeneration` fence.

```lua
local core, coreError = exports.synex_core:GetAPI('^1.0.0')
if not core then return nil, coreError end

local notify, apiError = exports.synex_notify:GetAPI('^1.0.0')
if not notify then return nil, apiError end

local session, sessionError = core.Players.getBySource(playerSource)
if not session then return nil, sessionError end

local target = {
    source = session.source,
    sessionId = session.id,
    sourceGeneration = session.sourceGeneration,
}

local handle, notifyError = notify.send(target, {
    kind = 'toast',
    tone = 'info',
    priority = 'normal',
    title = 'Garage updated',
    message = 'Your vehicle is available from this location.',
    dedupeKey = 'garage.vehicle.updated',
    dedupePolicy = 'replace',
})

if not handle then return nil, notifyError end
```

The server re-resolves that exact session before admission and delivery. Source
reuse or a stale generation returns `NOTIFY_TARGET_STALE` rather than reaching a
new occupant.

## Progress quick start

One operation should use one mutable surface:

```lua
local handle, progressError = notify.progress(target, {
    tone = 'info',
    priority = 'normal',
    title = 'Purchasing vehicle',
    message = 'Authorizing payment…',
    progress = {
        state = 'RUNNING',
        mode = 'determinate',
        value = 1,
        maximum = 3,
    },
})
if not handle then return nil, progressError end

handle, progressError = handle:update({
    message = 'Assigning ownership…',
    progress = {
        state = 'RUNNING',
        mode = 'determinate',
        value = 2,
        maximum = 3,
    },
})
if not handle then return nil, progressError end

handle, progressError = handle:success('Vehicle purchased')
if not handle then return nil, progressError end
```

Keep and reuse the newest handle revision. Do not invent percentage progress
when the backend does not know it; omit `progress` or choose
`mode = 'indeterminate'`.

## Dependencies and storage

- `synex_core` is required.
- `synex_ui` is optional at resource level but is the normal renderer.
- `synex_bridge` is optional. It exposes the partial server adapter plus
  default-denied QB/QBX/ESX function/export mappings for bounded local normal
  toasts; caller-opaque legacy notification events remain unsupported.
- `synex_control` may consume Notify's provider through Core; Notify has no hard
  dependency on Control.
- There is no database, migration, offline inbox, or durable replay.

With `synex_ui` unavailable, health is degraded. Ordinary gameplay notifications
are not mirrored to a native feed; only the controlled critical text fallback is
eligible, without actions. An upsert retained in the UI store with
`delivered = false` is also treated as a client transport failure: it produces
no display metric or sound. A critical signal whose exact browser-active ACK is
still absent after 1,250 ms uses the same text-only fallback at most once per
content generation. Non-critical signals never fan out into a native feed.

## Maturity

> Status: **Experimental Alpha.**

The public API and contracts are experimental. Automated Lua and browser tests
exercise deterministic validation and orchestration paths, but the exact
candidate has not established production maturity. Live FXServer/real-client
acceptance is still required for source reuse, resource restarts, CEF focus and
accessibility, safe-zone/ultrawide layout, keyboard/gamepad actions, UI recovery,
native fallback, shared-UI sound/device behavior, and measured
Resmon/gameplay performance.

## Guide

- [Architecture](architecture.md)
- [Lifecycle and revisions](lifecycle.md)
- [Kinds](kinds.md), [tones](tones.md), and [priorities](priorities.md)
- [Queue](queue.md), [rate limits](rate-limits.md),
  [deduplication](deduplication.md), and [grouping](grouping.md)
- [Progress](progress.md) and [actions](actions.md)
- [Accessibility](accessibility.md) and [visual language](visual-language.md)
- [Security](security.md), [compatibility](compatibility.md), and
  [diagnostics](diagnostics.md)
- [API reference and development](development.md)
