# NUI safety

## Closed means absent

When no surface is open:

- React renders no application surface;
- `html`, `body`, and `#root` are transparent;
- the root does not receive pointer events;
- no opaque fullscreen backdrop or pseudo-element remains;
- the shared frame does not itself retain focus;
- controller polling and UI timers for shared surfaces are inactive;
- no hidden component intercepts keyboard, mouse, or controller input.

The focus arbiter may intentionally keep native focus assigned to a different
resource-owned NUI while that resource holds the active lease. Its approved
owner helper applies and releases focus inside that resource context. When no
valid lease remains, the applicable helper or shared runtime applies
`SetNuiFocusKeepInput(false)` and `SetNuiFocus(false, false)`, and the bounded
input loop stops. An external active lease never makes the otherwise empty
shared frame visible or pointer-active.

Opacity alone is insufficient: an invisible mounted overlay can still block
clicks or retain focus.

## Ready and failure lifecycle

The client holds desired state until the browser completes a validated ready
handshake. It never takes focus before readiness. Browser reload marks the
runtime unhealthy, fences the previous browser instance, settles stale requests,
and resynchronizes current owner-bound state.

Every close path travels back through Lua so the focus authority can release or
restore leases. Escape/Back must not merely hide React. An error boundary shown
while focused must preserve a working close path.

## Static, local surface

- Production scripts, CSS, fonts, and icons are packaged locally.
- CSP rejects unneeded remote content.
- Vite emits relative asset paths compatible with the resource-local page.
- Strict NUI callback mode is enabled.
- Browser callbacks target `GetParentResourceName()` and static routes.
- No arbitrary HTML, SVG, URL, event, command, or native selector is accepted.

## Resource cleanup

Owner stop clears that resource's surfaces, leases, and pending requests. Runtime
stop clears all state, asks the browser to shut down, stops input work, and
signals every loaded owner helper to release native focus locally. Helpers
re-register after a runtime restart and will not apply new focus until they have
pulled a state from the new boot generation.

## Consumer prohibition

Participating Synex consumers must not call `SetNuiFocus` or
`SetNuiFocusKeepInput` directly. Doing so bypasses owner epochs, arbitration,
cleanup, health reporting, and focus restoration. A consumer with a dedicated
interactive NUI must load `@synex_ui/client/owner_focus.lua`; application code
still acquires and releases leases through the owner-bound `GetAPI` facade.

The helper bridge is coordination inside the client runtime, not a security
boundary against a modified client. NUI values and resulting domain actions
remain untrusted until an authoritative server validates them.

## Acceptance gate

Closed-state transparency, click-through, zero hidden work, Escape recovery,
owner stop, runtime restart, browser reload, reconnect, and callback strict mode
must be verified using the exact packaged output in FiveM. That acceptance is
**NOT YET VERIFIED**.
