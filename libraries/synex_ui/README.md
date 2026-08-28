# Synex UI

`synex_ui` is the shared UI foundation for Synex. It combines the build-time
`@synex/ui` React package with a small owner-bound FiveM NUI runtime.

The package supplies tokens, materials, accessible components, and large-data
primitives. The runtime supplies focus/input arbitration and generic shared
surfaces. Domain applications still own their own state, server operations, and
large NUI bundles.

> Status: **Experimental Alpha implementation candidate.** Automated and browser
> verification does not replace the outstanding real FiveM/CEF acceptance pass.

## Boundaries

- Build-time consumers import `@synex/ui`; they do not render their product UI
  through a central live browser.
- The `synex_ui` resource renders only `alert`, `confirm`, `input`, `form`,
  `select`, `menu`, and `contextMenu` descriptors.
- `synex_control` has no runtime dependency on `synex_ui`.
- The runtime owns no SQL tables and no money, inventory, group, identity,
  vehicle, permission, or other domain state.
- Participating consumer application code must not call `SetNuiFocus` or
  `SetNuiFocusKeepInput` directly. Dedicated interactive NUIs load the approved
  owner-focus helper so Cfx natives execute in the correct resource context.

## Build-time package

The repository root is an npm workspace. Install and build with the locked root
dependency graph:

- Node.js 22.12 or newer;
- npm 10 or newer.

```console
npm ci
npm run build:ui
```

In a workspace consumer:

```tsx
import "@synex/ui/styles.css";
import { ActionRow, Button, Field, Input, Stack, Surface } from "@synex/ui";

export function ExamplePanel() {
  return (
    <div className="sx-root">
      <Surface material="elevated" elevation={2}>
        <Stack gap="var(--sx-space-5)">
          <Field label="Display name" required>
            <Input maxLength={48} />
          </Field>
          <ActionRow>
            <Button>Continue</Button>
          </ActionRow>
        </Stack>
      </Surface>
    </div>
  );
}
```

Public exports include foundation, action, form, selection, navigation,
overlay, menu, feedback, data-display, utility, virtualization, tree, data-grid,
drag/reorder, command/search, and chart-token primitives. See the
[component reference](../../docs/ui/components.md).

## FiveM runtime

Deploy the built resource as `synex_ui` on the FiveM resource path and start it
after `synex_core`. Its manifest points at `web/dist/index.html`; build output is
generated, not edited by hand.

Acquire a versioned owner-bound facade at the export boundary:

```lua
local UI, uiError = exports.synex_ui:GetAPI('^1.0.0')

if UI == nil then
    print(('synex_ui unavailable: %s'):format(uiError.code))
    return
end
```

The facade exposes:

```text
acquireFocus(options)       releaseFocus(leaseId)
getFocusLease(leaseId)
alert(request)              confirm(request)
input(request)              form(request)
select(request)             menu(request)
contextMenu(request)        closeOwner(disposition?)
getPreferences()            setPreferences(patch)
getHealth()                 getDiagnostics()
```

Runtime descriptors are deliberately finite. `select` accepts a flat option
set plus optional `multiple`, `searchable`, and `placeholder` fields. `menu`
and `contextMenu` accept sectioned option trees up to three levels deep;
`contextMenu.anchor` uses normalized `x`/`y` coordinates in the inclusive
`0..1` range. Option icons must use one of the fixed packaged registry keys
listed in [Transport](../../docs/ui/transport.md#content-restrictions). Menu
options may carry bounded JSON-object `metadata`; selecting one returns its
`id` and metadata without interpreting either as markup, a URL, or executable
content.

The facade also publishes the negotiated API/protocol versions, captured owner,
focus modes, priority classes, layers, limits, stable error codes, and health
reason registry as read-only copied metadata.

Shared surface calls wait for a bounded result and must run in a yieldable Cfx
context:

```lua
CreateThread(function()
    local result, requestError = UI.confirm({
        title = 'Discard changes?',
        description = 'Your local edits will be lost.',
        tone = 'danger',
        confirmLabel = 'Discard',
        cancelLabel = 'Keep editing',
        timeoutMs = 30000,
    })

    if result ~= nil and result.status == 'confirmed' then
        -- Request the domain action from its authoritative server boundary.
        -- A UI confirmation is not authorization.
    elseif requestError ~= nil then
        print(('confirmation failed: %s'):format(requestError.code))
    end
end)
```

For a resource-owned interactive NUI, acquire a lease before opening:

```lua
-- fxmanifest.lua: load the helper before application client scripts.
dependency 'synex_ui'

client_scripts {
    '@synex_ui/client/owner_focus.lua',
    'client/*.lua',
}
```

The helper is intentionally listed in `synex_ui`'s manifest files and is loaded
by reference; do not copy or modify it per consumer.

```lua
local lease, focusError = UI.acquireFocus({
    mode = 'EXCLUSIVE',
    priority = 'NORMAL',
    conflict = 'DENY',
    reason = 'example_panel',
})

if lease ~= nil then
    -- Open the resource-owned NUI.
    -- Later, route every close path through:
    UI.releaseFocus(lease.leaseId)
end
```

Available modes are `PASSIVE`, `KEYBOARD`, `POINTER`, and `EXCLUSIVE`.
Priorities are `PASSIVE`, `NORMAL`, `MODAL`, `CRITICAL`, and `SYSTEM`; conflict
policies are `DENY`, `QUEUE`, and `SUSPEND`. `KEEP_GAME_INPUT` is not part of the
current public contract. `CRITICAL` and `SYSTEM` are visible contract constants
but runtime-reserved; external resource facades cannot acquire them.

The facade captures `ownerResource` and `ownerEpoch`; callers cannot supply or
override them. On owner stop, the runtime cancels pending requests and removes
that owner's surfaces and leases.

Direct non-passive leases require the compatible helper to register and
acknowledge the current central boot generation. The arbiter retains the stack
and desired state, while the helper performs resource-scoped `SetNuiFocus` and
direct-NUI `SendNUIMessage` calls. Stale wakeups and acknowledgements cannot
apply an older revision. Owner stop and `synex_ui` stop release locally; a
central restart requires re-registration before focus can be granted again.

Interactive standalone leases are fail-closed with `UI_FOCUS_BUSY` while a
shared runtime surface is active, preventing browser visibility and native
focus ownership from diverging. Passive leases remain non-interactive.

## Security and lifecycle

- Browser/client data is untrusted and bounded.
- Callback and message routes are static and versioned.
- Descriptors reject arbitrary HTML, SVG, URLs, scripts, routes, and events.
- Every NUI callback returns one response envelope.
- Protected mutations remain server-authoritative.
- The closed shared frame is transparent, unmounted, and pointer-free; it retains
  no focus of its own. With no valid active lease, native focus and input polling
  are also fully released.
- Runtime stop clears keep-input and focus even during recovery.
- The owner-focus bridge is coordination, not a hostile-client security
  boundary. Protected actions remain server-authoritative.

## Development commands

From the repository root:

```console
npm run check:ui
npm run test:ui
npm run build:ui
npm run test:ui:visual
```

The Design Lab is browser-only development infrastructure:

```console
npm run dev:playground --workspace @synex/ui
```

It must never be treated as proof of FiveM/CEF behavior.

## Documentation

- [UI documentation index](../../docs/ui/README.md)
- [Architecture](../../docs/ui/architecture.md)
- [Design language](../../docs/ui/design-language.md)
- [Focus arbitration](../../docs/ui/focus.md)
- [Transport and trust boundaries](../../docs/ui/transport.md)
- [NUI safety](../../docs/ui/nui-safety.md)
- [Development and acceptance](../../docs/ui/development.md)

Real FiveM/CEF loading, safe-zone behavior, glass over gameplay, controller/focus
behavior, and runtime performance are **NOT YET VERIFIED**.
