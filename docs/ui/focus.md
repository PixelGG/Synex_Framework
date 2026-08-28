# Focus arbitration

Participating Synex resources do not call `SetNuiFocus` or
`SetNuiFocusKeepInput` from application code. They request an owner-bound lease
from `synex_ui`. The arbiter remains the authoritative coordinator, while the
native call is executed in the resource context that owns the focused NUI:

- shared `synex_ui` surfaces are focused by `synex_ui/client.lua`;
- a resource-owned NUI is focused by the approved
  `@synex_ui/client/owner_focus.lua` helper loaded into that resource.

This split is required because Cfx NUI focus and message delivery are
resource-scoped. Calling those natives centrally would focus or message the
empty `synex_ui` frame instead of the owner's dedicated NUI frame.

## Owner-focus helper

A consumer that uses `acquireFocus` for its own interactive NUI must load the
versioned helper before its application client scripts:

```lua
dependency 'synex_ui'

client_scripts {
    '@synex_ui/client/owner_focus.lua',
    'client/*.lua',
}
```

The helper registers through `RegisterFocusAgent`, pulls authoritative state
through `GetFocusAgentState`, applies the requested native focus in the owner
resource context, and acknowledges the exact boot generation, owner epoch, and
monotonic revision through `AcknowledgeFocusAgent`. These three exports form an
internal coordination bridge; application code should use only `GetAPI`.

Wake events contain no authoritative desired state. They only prompt a fresh
pull, so delayed wakeups and acknowledgements cannot apply a superseded
revision. Gamepad intents for a direct owner lease follow the same pull and
generation fence, then `SendNUIMessage` executes in the owner context.

Without a registered, compatible, and fully acknowledged helper, direct
interactive acquisition fails closed with `UI_FOCUS_DENIED`. Shared surfaces
do not require a helper, and `PASSIVE` direct leases do not invoke focus natives.

## Focus modes

| Mode | Intent |
| --- | --- |
| `PASSIVE` | Display-only surface; no keyboard or pointer focus. |
| `KEYBOARD` | Keyboard/controller-oriented interaction without a cursor. |
| `POINTER` | Cursor-oriented interaction. |
| `EXCLUSIVE` | Modal text/keyboard and pointer interaction. |

The current runtime does not expose a keep-game-input mode. Continued gameplay
input while a NUI owns focus needs separate design, control-conflict analysis,
and real-client evidence before it may become public API.

## Priority classes

Priority is explicit: `PASSIVE`, `NORMAL`, `MODAL`, `CRITICAL`, or `SYSTEM`.
Most resource UI belongs at `NORMAL` or `MODAL`. `CRITICAL` and `SYSTEM` are not
visual emphasis levels. They are runtime-reserved and external resource facades
receive `UI_FOCUS_DENIED` if they request either class.

## Conflict policies

- `DENY` returns a stable busy/denied result when another owner holds an
  incompatible lease.
- `QUEUE` records a bounded pending lease and promotes it when the active stack
  is free.
- `SUSPEND` may place a higher-priority lease above the current one. Releasing
  it restores the most recent valid lease beneath it.

A resource may nest its own leases. Cross-owner suspension requires a strictly
higher priority. Queues are bounded and are not an unlimited task scheduler.

An interactive standalone lease is rejected with `UI_FOCUS_BUSY` while a
shared runtime surface is open. This prevents a resource-owned NUI from taking
native focus while the shared browser still displays another owner's surface.
Shared surfaces may still stack through the runtime because their visual and
focus ownership advance together. Passive leases do not take native focus and
remain permitted.

## Lifecycle

1. The export boundary captures the invoking resource and creates or reuses its
   current owner epoch.
2. A valid facade requests a lease with mode, priority, conflict policy, and a
   bounded diagnostic reason.
3. The runtime grants, queues, or rejects the request.
4. Native focus is applied only after the shared NUI ready handshake and, for a
   direct lease, an exact owner-agent acknowledgement.
5. A shared surface suspending a direct lease first releases owner focus, then
   focuses the shared frame. Closing it reverses that handoff.
6. On release, the runtime restores the next valid suspended or queued owner.
7. On owner stop, every lease and focus-agent record for that owner epoch is
   removed automatically; the owner helper also clears native focus locally.
8. On `synex_ui` stop, every loaded helper releases locally. On restart it
   re-registers against the new boot generation before another transition.

The facade can inspect one of its own leases with `getFocusLease(leaseId)`. It
cannot enumerate or obtain another owner's lease through that method; broader
stack information is reserved for the bounded diagnostics snapshot.

Stale facades and lease identifiers from expired epochs are rejected. A caller
cannot release another resource's lease through its facade.

## Failure handling

Callers must handle `UI_NOT_READY`, `UI_FOCUS_BUSY`, `UI_FOCUS_DENIED`,
`UI_FOCUS_LEASE_INVALID`, `UI_OWNER_STOPPED`, and `UI_OWNER_STALE`. A failed
acquisition must not open a resource-owned interactive NUI anyway.

The owner-focus bridge is deterministic client-side coordination, not a
hostile-client security boundary. Any persistent, economic, permission, or
other protected action initiated from a NUI remains server-authoritative and
must be validated independently.

## Acceptance gate

Stack restoration, owner-stop cleanup, runtime restart, focus/cursor recovery,
and interaction with other NUI resources must be exercised in the exact FiveM
client. That live focus matrix is **NOT YET VERIFIED**.
