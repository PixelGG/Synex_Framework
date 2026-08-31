# Notify compatibility boundary

The preferred integration surface is the native, caller-bound Synex API:

```lua
local notify, notifyError = exports.synex_notify:GetAPI('^1.0.0')
```

On the server, callers may also consume the local Core service
`synex.notify@1`. Both paths preserve the real resource principal. The Core
service validates its `callerEpoch`, while the direct facade, service, and
Bridge adapter all resolve that principal to the same Notify-owned incarnation
epoch used by records and handles. The canonical payload remains the only
source of Kind, Tone, Priority, progress, dedupe, grouping, action, and lifetime
semantics.

## Implemented QB, QBX, and ESX boundary

The Experimental Alpha Bridge now contains reviewed, `PARTIAL` mappings for
these client function/export shapes:

| Provider | Mapped client shape | Canonical result |
| --- | --- | --- |
| QB | `QBCore.Functions.Notify(text, type?, length?, icon?)` and the historical `qb-core` `Notify` export | local normal toast |
| QBX | `exports.qbx_core:Notify(text, type?, duration?, subTitle?, ...)` | local normal toast |
| ESX | `ESX.ShowNotification(...)` and `ESX.ShowAdvancedNotification(...)` | local normal toast |

The provider normalizes the immediate legacy caller and requests a private
compatibility facade from `synex_notify`. That facade can be acquired only by
the matching reviewed provider resource (`synex_bridge_qb`,
`synex_bridge_qbx`, or `synex_bridge_esx`). The resulting notification remains
owned by the actual consumer resource and its Notify epoch; provider and facade
resources do not become the owner.

The mapping is deliberately narrow:

- kind is always `toast`, priority is always `normal`, and origin is always
  `LOCAL`;
- the legacy type maps `primary/info/inform`, `success`, `warning/warn`, and
  `error/danger`; an unknown type becomes `neutral` rather than privileged;
- duration is clamped to the canonical `1,500..30,000 ms` range;
- title and body are bounded plain text; control bytes, malformed UTF-8, and
  strings containing markup delimiters are rejected;
- known GTA formatting markers are removed before canonical validation;
- legacy icon, texture, color, style, placement, flash, and similar decorative
  options never cross into the canonical request;
- target, server/system origin, actions, progress, banner, high, and critical
  presentation cannot be selected through this facade.

Unknown or unsafe legacy input fails closed and produces no notification.
Complex legacy notification behavior must be migrated to a native Signal
Surface, dialog, or owning domain UI instead of being approximated.

## Authorization and default-deny behavior

No compatibility profile or consumer is enabled in the checked-in
configuration. Installing the provider resources therefore enables nothing by
itself. Bridge must first resolve an explicit consumer/profile for
`client.notification.send`; the consumer must pass the matching
`synex.compat.<provider>.read` check and the delegated
`synex.notify.send` check. The provider receives the resulting bounded consumer
allowlist through its server-origin lifecycle projection and clears it on
logout, replacement, invalid projection, or provider stop.

That projection is a policy snapshot inside the trusted server-resource
boundary, not a cryptographic client credential. The security boundary at the
presentation call is the Cfx immediate caller identity plus the restricted
local-only Notify facade. A client cannot use the mapping to address another
player or obtain server, system, banner, high, or critical authority. Server
resources are operator-trusted code and can already emit arbitrary client
events; untrusted server resources are outside the framework's resource-isolation
model.

## Intentionally unsupported event aliases

Legacy notification events are not registered:

```text
QBCore:Notify
QBCore:Client:Notify
qbx_core:client:notify
esx:showNotification
esx:showAdvancedNotification
```

A raw client event does not preserve the immediate invoking resource. Accepting
a consumer name in its payload would turn ownership and policy into
client-selected data. Function and export calls can retain
`GetInvokingResource` and are therefore the only implemented compatibility
path.

## Server-side Bridge adapter

When `synex_bridge` is running, Notify also registers a `PARTIAL`
`synex.notify@1.0.0` domain adapter with one server-side `send` operation. Its
closed payload is `{ target, notification }`; the target remains the complete
session/source-generation fence, and Notify binds ownership to Bridge's
resolved consumer. This generic adapter does not persist offline notifications,
create a client network shim, or bypass normal send/priority capabilities.

## Semantic migration

Legacy APIs often collapse several dimensions into one `type`. Native migration
should split them deliberately:

```lua
-- Legacy idea: Notify('Purchase failed', 'error', 5000)
local handle, notifyError = notify.show({
    kind = 'toast',
    tone = 'danger',
    priority = 'normal',
    title = 'Purchase failed',
    durationMs = 5000,
})
```

An error tone does not imply high or critical priority. Progress should become
one mutable progress handle instead of multiple translated toasts.

## Acceptance status

Native Notify and the three mapping boundaries have repository-level automated
coverage. They remain Experimental Alpha: checked-in profiles and consumers are
empty, no compatibility flow is certified, and exact FXServer/client facade,
provider restart, resource cleanup, and CEF presentation acceptance are still
required before deployment claims can be made.
