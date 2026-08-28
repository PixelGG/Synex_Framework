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
```

The packaged runtime keeps scripts, fonts, images, and stylesheet files local.
Its CSP permits inline style application because React components and the
screen/material engine set bounded CSS custom properties at runtime. The
`connect-src` HTTPS scheme is required because the standard Cfx callback host
uses the resource name (`https://synex_ui/...`), which is not a valid CSP host
source when it contains an underscore. This does not create a dynamic transport
API: browser code still constructs only the captured parent resource plus the
six static routes above, and descriptor payloads reject URL fields. A Chromium
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

## Acceptance gate

Malformed-callback, reload, timeout, duplicate, replay, stale-revision, and
owner-stop behavior must still be exercised against the production NUI in a real
client. FiveM/CEF transport acceptance is **NOT YET VERIFIED**.
