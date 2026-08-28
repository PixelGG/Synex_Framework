# Overview

Synex UI gives independent resources a common visual and interaction model
without turning every screen into one central application.

## What it provides

The build-time package provides:

- a three-layer token system;
- local typography, material, motion, density, and quality rules;
- generic layout, action, form, selection, navigation, overlay, menu, feedback,
  data-display, utility, and large-data primitives;
- accessible keyboard behavior and reusable React contracts;
- a browser Design Lab for development scenarios.

The FiveM runtime provides:

- owner-bound focus leases and conflict handling;
- mouse, keyboard, and controller intent routing;
- generic alerts, confirmations, inputs, forms, selects, and menus;
- versioned, correlated, bounded NUI messages and callbacks;
- automatic cleanup when an owning resource stops;
- client-local UI preferences, health, limits, and metrics.

## What it does not provide

`synex_ui` does not own or mutate money, accounts, inventories, groups,
characters, vehicles, permissions, or any other domain state. It does not accept
arbitrary event names, routes, HTML, SVG, or URLs from callers. It has no SQL
schema and is not a server-authority substitute.

Large domain interfaces keep their own resource, NUI lifecycle, state model, and
server boundary. They consume `@synex/ui` while compiling. Only genuinely shared
surfaces and coordination use the live `synex_ui` resource.

## Consumer rules

- Import package components and `@synex/ui/styles.css` at build time.
- Use the runtime facade for shared surfaces or focus arbitration.
- Do not call `SetNuiFocus` or `SetNuiFocusKeepInput` directly from a
  participating Synex resource.
- Do not send protected values through the generic UI runtime and treat them as
  authoritative.
- Release explicit leases and close surfaces on normal completion; owner-stop
  cleanup is the recovery path, not the primary close path.
- Keep every domain mutation server-authoritative and separately validated.

## Architectural anti-patterns

- Do not apply glass to every surface.
- Do not hardcode colors or z-index values around the token/layer system.
- Do not call `SetNuiFocus` directly from a native Synex consumer.
- Do not accept arbitrary HTML, SVG, URLs, event names, or routes in UI payloads.
- Do not duplicate a domain application or its state inside `synex_ui`.

## Closed-state contract

When no runtime surface is open, the browser renders no application surface.
`html`, `body`, and `#root` stay transparent and pointer-free; React content is
unmounted; and that shared frame performs no rendering work. The frame does not
retain focus. Native focus and bounded input arbitration can remain intentionally
active for a different resource-owned NUI only while that resource holds the
active runtime lease. With no shared surface and no active lease, polling/timers
are stopped and focus is released. A hidden opaque layer is a defect, even if it
looks transparent on one scene.

## Current acceptance boundary

The checked-in implementation and browser evidence must still be followed by a
real client pass. FiveM/CEF loading, callback behavior, focus restoration,
safe-zone calibration, glass readability over gameplay, controller navigation,
and performance on representative hardware are **NOT YET VERIFIED**.
