# Synex UI documentation

`synex_ui` is the shared interface foundation for Synex. It has two deliberately
separate roles:

1. **`@synex/ui`** is a build-time React package. A resource imports its tokens,
   styles, and components into that resource's own NUI bundle.
2. **`synex_ui`** is a small FiveM client resource. It owns cross-resource focus
   arbitration, input routing, generic shared surfaces, lifecycle cleanup, and a
   bounded NUI transport.

It is not a central home for inventory, finance, character, vehicle, or other
domain state. `synex_control` also remains fully usable without `synex_ui` at
runtime.

The runtime also exposes a passive Signal Surface for `synex_notify`. Its raw
signal upsert/remove/snapshot operations are bounded, revision-fenced,
focus-free, and reserved exclusively for the immediate `synex_notify` resource;
another facade owner receives `UI_SIGNAL_DENIED`. Notify owns feedback semantics
and lifecycle, while `synex_ui` owns only validated presentation and reports the
exact browser-active surfaces back through a generation/revision-fenced ACK.
An upsert result includes `delivered`: `false` means the signal is retained for
later synchronization but was not sent through a ready/successful browser
transport. It is not a paint or display receipt.

> Status: **Experimental Alpha.** This label applies to the UI package and
> runtime only; it does not inherit the frozen Core
> Production-Beta decision.

## Guide

- [Overview](overview.md)
- [Architecture](architecture.md)
- [Design language](design-language.md)
- [Tokens](tokens.md)
- [Materials](materials.md)
- [Glass and transparency](glass.md)
- [Components](components.md)
- [Focus arbitration](focus.md)
- [Input model](input.md)
- [Gamepad](gamepad.md)
- [Accessibility](accessibility.md)
- [Transport and trust boundaries](transport.md)
- [Performance](performance.md)
- [Theming](theming.md)
- [Quality profiles](quality-profiles.md)
- [NUI safety](nui-safety.md)
- [Development and verification](development.md)
- [Notify visual and orchestration boundary](../notify/visual-language.md)

## Verification status

Static checks, unit/component tests, browser scenarios, and production builds
provide development evidence only. Real FiveM/CEF behavior, safe-zone mapping,
glass over moving gameplay, controller behavior, screen-reader/accessibility
behavior, focus recovery, and measured Resmon/runtime performance are **not yet
verified**. They remain required acceptance gates before `synex_ui` can be
described as live-approved.
