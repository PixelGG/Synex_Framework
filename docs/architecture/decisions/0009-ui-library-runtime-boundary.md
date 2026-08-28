# ADR-0009: Build-time UI library and owner-bound runtime

- Status: Accepted
- Date: 2026-08-28
- Scope: `synex_ui`

## Context

Synex resources need a shared visual and interaction system, but large domain
interfaces must retain their own NUI lifecycle and bundle. A central browser
application containing inventory, banking, phone, vehicles, and future domains
would create a single failure boundary, obscure ownership, and couple every
resource to one runtime.

FiveM also has genuinely shared client concerns: NUI focus, input arbitration,
modal conflicts, resource-stop cleanup, and bounded request/response transport.
Those concerns cannot be solved by CSS or build-time components alone.

## Decision

`libraries/synex_ui` is both:

1. the `@synex/ui` build-time package containing tokens, materials, motion,
   icons, accessibility behavior, layouts, and generic UI components; and
2. the small `synex_ui` FiveM resource rendering only shared generic surfaces
   and coordinating focus, input, layers, ownership, and NUI transport.

Domain resources compile the package into their own NUI. They do not delegate
their screens or domain state to the central runtime.

The runtime captures the invoking resource at the Cfx export boundary and binds
every facade, lease, surface, and request to a client-local owner epoch. Browser
payloads cannot select an owner, route, native, event, URL, HTML, or SVG. Static
callback routes validate bounded versioned envelopes, reply exactly once, and
fence stopped or stale owners.

`synex_control` remains runtime-independent. The UI runtime has no SQL tables,
server service, domain mutation API, or Control dependency. Client-local visual
preferences use versioned KVP storage only.

## Consequences

- Domain UIs share Synex design and behavior without a live central component
  dependency.
- Common dialogs and focus behavior are consistent and owner-cleaned.
- Separate NUI frames still require cooperative focus and z-order behavior;
  CSS cannot globally order independent resources.
- Browser regression tests do not prove CEF, focus, safe-zone, gamepad, blur, or
  gameplay performance. Those remain explicit live acceptance gates.
- Direct `SetNuiFocus` calls in participating Synex resources are an
  architectural violation because they bypass arbitration.
