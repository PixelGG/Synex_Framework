# Transport and trust boundaries

The `synex_ui` browser and client communicate through one versioned protocol and
a finite set of static callbacks. Both directions are untrusted at runtime.

## Game-to-browser envelope

Messages include:

- `protocolVersion`;
- a unique `messageId`;
- a static message `type`;
- `ownerResource` and `ownerEpoch`;
- a monotonic `revision` where ordering matters;
- a bounded JSON `payload`.

Only declared message types are accepted. The browser validates the envelope,
bounds, owner fields, and surface descriptor before changing state. Unsupported
versions, malformed payloads, conflicting owners, and stale revisions fail
closed.

`runtime:sync` is also the bounded patch channel used for screen metrics,
preferences, input-device changes, and full surface reconciliation. Omitting
`surfaces` preserves the browser's current surface set; supplying a `surfaces`
array replaces it with the entries that pass descriptor validation. Invalid
entries never enter browser state. This distinction prevents a screen-metrics-
only synchronization from accidentally closing active surfaces.

The same envelope family carries two retained passive-signal message types,
`signal:upsert` and `signal:remove`, plus the non-retained `signal:sound`
effect. A full `runtime:sync` may carry at most
eight signals plus a monotonic signal generation for browser-restart
reconciliation. Signal identity is the exact owner resource, owner epoch and
signal ID; stale revisions or generations fail closed. This transport has no
callback route that can select an arbitrary server event.

The raw Lua facade methods `upsertSignal`, `removeSignal`,
`getSignalSnapshot`, and `bindSignalCapacity` are reserved to the immediate
`synex_notify` resource. Another owner receives `UI_SIGNAL_DENIED` for signal
transport and never receives the capacity-binding method; passive signals are
not a general cross-resource UI bus. The capacity callback is callable-only,
bound to the current owner epoch, and contains exactly the owner, epoch,
one-to-four capacity, and the closed central UI preference snapshot. This same
private callback updates Notify when scale, density, reduced motion,
transparency, or contrast changes even if capacity stays constant. It must
explicitly return `true`; the next-turn dispatcher coalesces to at most one
pending callback per binding. Thrown, stale, `nil`, or `false` results remove
the subscriber and fail closed.

Only the immediate `synex_notify` facade receives `playSignalSound`. Its exact
caller request is `{ tone, volume }`: tone is one of `neutral`, `info`, `success`,
`warning`, `danger`, or `critical`, and volume is an integer from 1 through
100. Lua applies a 50 ms cooldown and an eight-per-second window bound before
sending the one-shot envelope. Lua injects the current browser boot ID, so the
internal browser-only payload is exactly `{ tone, volume, browserBootId }` and
the caller cannot choose that fence. The browser requires the current boot,
remembers the latest 64 message IDs, rejects stale owner epochs, repeats the
50 ms/eight-per-second pressure limits without resetting them on owner-epoch
changes, and permits at most four simultaneous oscillator voices. A shutdown,
browser replacement, or component unmount closes audio and clears the bounded
fence. The effect is never stored in the reducer, so runtime synchronization,
rendering, and browser restart cannot replay it. Audio unavailability or a
denied context resume fails silently without changing NUI visibility, focus,
or input state.

An accepted `upsertSignal` returns
`{ generation, signal, delivered = boolean }`. The revision is retained in the
bounded Lua UI store in either case. `delivered = true` means the upsert envelope
was sent while the NUI was ready and the send call succeeded;
`delivered = false` means only store admission succeeded. The latter can be
recovered by a later ready/full synchronization, but is not evidence of browser
receipt, DOM presentation, or paint. Notify records it as a transport failure,
does not play sound, and reserves its once-per-content-generation text fallback
for critical signals only. A synchronously successful send still requires an
exact browser-active ACK; absence for 1,250 ms activates that same bounded
critical fallback.

## Browser-to-client callbacks

The browser posts only to static routes on
`https://${GetParentResourceName()}/...`. The route name never comes from a
surface payload. Each Lua callback validates its exact object shape, applies a
route-specific rate policy, and calls the response callback exactly once.

Responses are object-shaped envelopes:

```ts
type NuiResponse<T> =
  | { ok: true; data?: T }
  | { ok: false; error: { code: string; message?: string } };
```

Protocol version 1 exposes only these callback routes:

```text
runtime:ready          runtime:respond
runtime:close          runtime:input
runtime:preferences    runtime:error
runtime:signals:visible
```

`runtime:signals:visible` is the passive-signal presentation ACK. The browser
posts only surfaces actually in the Signal Rail's `active` phase; the 140 ms
dismissing retention and a selected signal still waiting for a physical slot are
excluded. The closed request carries `browserBootId`, the current signal
`generation`, a strictly increasing per-browser-boot `presentationRevision`,
the current adaptive `capacity` from one through four, and no more than that
many exact `{ownerResource, ownerEpoch, signalId, revision}` entries. Lua
recomputes the capacity from native screen metrics and preferences and accepts
the report only when every fence equals its retained signal state.

The browser coalesces a changed active set and retries a failed callback after
150, 500, 1,500, and 5,000 ms, then at the five-second ceiling until success or a
new target replaces it. `synex_notify` also polls the private snapshot while
action tokens exist. A fetch abort or timeout never implies acceptance: action
invocation through F9/F10 remains fail-closed until Notify confirms the exact
current action-bearing revision. A new hint is not introduced before the first
active-surface ACK.

The packaged runtime keeps scripts, fonts, images, and stylesheet files local.
Its CSP permits inline style application because React components and the
screen/material engine set bounded CSS custom properties at runtime. The
`connect-src` HTTPS scheme is required because the standard Cfx callback host
uses the resource name (`https://synex_ui/...`), which is not a valid CSP host
source when it contains an underscore. This does not create a dynamic transport
API: browser code still constructs only the captured parent resource plus the
seven static routes above, and descriptor payloads reject URL fields. A Chromium
smoke test loads the packaged runtime, checks the CSP console, and exercises
dynamic screen and context-position styles.

Timeout, cancellation, stale responses, owner stop, browser reload, and runtime
shutdown settle pending work with stable error codes. A browser fetch abort does
not prove downstream work was cancelled.

## Bounds

The runtime limits serialized bytes, nesting depth, total entries, string size,
pending requests, surfaces per runtime and owner, fields, options, menu depth,
and focus leases. The Lua and browser validators are expected to enforce the
same public contract; parity tests guard drift.

The version 1 Lua facade publishes these current limits through `api.limits`:

| Bound | Value |
| --- | ---: |
| Serialized payload | 32 KiB |
| Nesting depth | 8 |
| Aggregate entries | 256 |
| String | 4,096 bytes |
| Pending requests | 64 |
| Active surfaces | 32 total / 8 per owner |
| Passive signals | 8 retained, reserved for `synex_notify`; adaptive 1-4 active/rendered |
| Signal actions | 2 per signal |
| Signal revision fences | 256 |
| Focus leases | 64 total / 16 per owner |
| Form fields | 24 |
| Options/menu items | 96 |
| Menu nesting | 3 levels |
| Timeout | 1,000–120,000 ms; 30,000 ms default |

These are protocol limits, not suggested normal payload sizes. Prefer smaller
targeted messages.

## Content restrictions

Descriptors may contain plain text, finite numbers, booleans, arrays, and
allowlisted option/field/icon identifiers. They may not contain arbitrary:

- HTML or `dangerouslySetInnerHTML` content;
- SVG markup;
- URLs, image sources, links, iframes, or scripts;
- Lua/server event names, commands, natives, exports, or callback routes.

Normal React interpolation is the rendering boundary. Icons come from the fixed
packaged registry, not markup supplied by a caller. Protocol version 1 accepts
only these keys:

```text
check           close           chevron-down    chevron-right
arrow-left      arrow-right     search           plus
minus           more            copy             eye
eye-off         info            warning          error
success         menu            command          signal
```

Select descriptors use flat options and may set `multiple`, `searchable`, and a
bounded `placeholder`. Menu and context-menu sections may contain option trees
up to three total levels deep and 96 aggregate items. Context menus require a
normalized `anchor` object whose `x` and `y` values are each within `0..1`.

## Authority

This transport is a presentation boundary, not authentication. NUI and client
input can be forged. Domain servers must re-derive player identity and protected
values, validate permission/ownership/state/proximity/ranges, rate-limit abuse,
and commit economic or persistent mutations atomically.

Strict callback mode provides origin isolation; it does not make the client
trusted.

`UI_SIGNAL_DENIED` reports an owner attempting to use Notify's private raw
signal transport. `UI_REQUEST_STALE` covers stale browser boot, generation,
`presentationRevision`, owner epoch, signal identity, or signal revision in a
visibility report.

## Acceptance gate

Malformed-callback, reload, timeout, duplicate, replay, stale-revision, and
owner-stop behavior must still be exercised against the production NUI in a real
client. FiveM/CEF transport acceptance is **NOT YET VERIFIED**.
